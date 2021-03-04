/*
 * Copyright (c) 2021, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import "FeedbackUpload.h"
#import "AppDelegate.h"
#import "Feedback.h"
#import <PsiphonTunnel/Reachability.h>

/// UserFeedback represents a user feedback submitted through the in-app feedback form.
@interface UserFeedback : NSString
@property (assign) NSInteger selectedThumbIndex;
@property (strong, nonatomic) NSString* comments;
@property (strong, nonatomic) NSString* email;
@property (assign, nonatomic) BOOL uploadDiagnostics;
@end

@implementation UserFeedback
@end

@implementation FeedbackUpload {
	dispatch_queue_t workQueue;
	ConnectionState connectionState;
	NSMutableArray<UserFeedback*>* pendingUploads;
	PsiphonTunnelFeedback *psiphonTunnelFeedback;
	BOOL uploadPaused;
}

- (id)initWithConnectionState:(ConnectionState)state {
	self = [super init];
	if (self) {
		self->workQueue = dispatch_queue_create("com.psiphon3.browser.FeedbackUploadQueue", DISPATCH_QUEUE_SERIAL);
		self->connectionState = state;
		self->pendingUploads = [[NSMutableArray alloc] init];
		self->uploadPaused = FALSE;
	}
	return self;
}

- (void)setConnectionState:(ConnectionState)state {
	dispatch_async(self->workQueue, ^{
		if (state != self->connectionState) {
			self->connectionState = state;

			if ([self->pendingUploads count] == 0) {
				return;
			}

			if (self->uploadPaused == FALSE) {
				[self stopSendingFeedback];
				self->uploadPaused = TRUE;
			} else {
				[self startSendingFeedback];
				self->uploadPaused = FALSE;
			}
		}
	});
}

- (void)uploadFeedbackWithSelectedThumbIndex:(NSInteger)selectedThumbIndex
									comments:(NSString*)comments
									   email:(NSString*)email
						   uploadDiagnostics:(BOOL)uploadDiagnostics {
	dispatch_async(self->workQueue, ^{
		UserFeedback *feedback = [[UserFeedback alloc] init];
		feedback.selectedThumbIndex = selectedThumbIndex;
		feedback.comments = comments;
		feedback.email = email;
		feedback.uploadDiagnostics = uploadDiagnostics;
		[self->pendingUploads addObject:feedback];
		// Start feedback upload if there is no ongoing upload. Otherwise, the feedback will be
		// uploaded when the previous uploads completes.
		if ([self->pendingUploads count] == 1) {
			assert(self->psiphonTunnelFeedback == nil);
			self->psiphonTunnelFeedback = [[PsiphonTunnelFeedback alloc] init];
			[self startSendingFeedback];
		}
	});
}

/// @warning must be called on the work queue.
- (void)stopSendingFeedback {
	assert([self->pendingUploads count] > 0);
	assert(self->psiphonTunnelFeedback != nil);
	[self->psiphonTunnelFeedback stopSendFeedback];
}

/// @warning must be called on the work queue.
- (void)startSendingFeedback {
	assert([self->pendingUploads count] > 0);

	if (self->connectionState == ConnectionStateConnecting ||
		self->connectionState == ConnectionStateWaitingForNetwork) {
		// Upload will be started when connection state is valid for upload.
		self->uploadPaused = TRUE;
		return;
	}

	NSString *config = [AppDelegate.sharedAppDelegate getPsiphonConfig];
	if (config == nil) {
		abort();
		return;
	}

	NSError *err;
	NSDictionary *configDict =
		[NSJSONSerialization JSONObjectWithData:[config dataUsingEncoding:NSUTF8StringEncoding]
										options:kNilOptions
										  error:&err];
	if (err != nil) {
		NSString *log = [NSString stringWithFormat:@"Failed to parse config JSON for feedback upload %@", err];
		[[PsiphonData sharedInstance] addDiagnosticEntry:[DiagnosticEntry msg:log]];
		abort();
		return;
	}

	if (self->connectionState == ConnectionStateConnected) {
		// Replace user configured proxy with local HTTP proxy exposed by Psiphon.
		NSMutableDictionary *newConfigDict = [NSMutableDictionary dictionaryWithDictionary:configDict];
		newConfigDict[@"UpstreamProxyURL"] = [NSString stringWithFormat:@"http://127.0.0.1:%ld",
											  (long)AppDelegate.sharedAppDelegate.httpProxyPort];
		[newConfigDict removeObjectForKey:@"CustomHeaders"];
		configDict = newConfigDict;
	}

	UserFeedback *feedback = [self->pendingUploads objectAtIndex:0];
	NSString *feedbackId = [Feedback generateFeedbackId];
	NSString *feedbackJSON = [Feedback generateFeedbackJSON:feedback.selectedThumbIndex
												  buildInfo:[PsiphonTunnel getBuildInfo]
												   comments:feedback.comments
													  email:feedback.email
										 sendDiagnosticInfo:feedback.uploadDiagnostics
												 feedbackId:feedbackId
											  psiphonConfig:configDict
											 clientPlatform:@"ios-browser"
											 connectionType:[self getConnectionType]
											   isJailbroken:[JailbreakCheck isDeviceJailbroken]
										  diagnosticEntries:[PsiphonData.sharedInstance.diagnosticHistory copy]
											  statusEntries:nil
													  error:&err];
	if (err != nil) {
		NSString *log = [NSString stringWithFormat:@"FeedbackUpload: failed to generate feedback JSON %@", err];
		[[PsiphonData sharedInstance] addDiagnosticEntry:[DiagnosticEntry msg:log]];
		[self->pendingUploads removeObjectAtIndex:0];
		return;
	}

	[self->psiphonTunnelFeedback startSendFeedback:feedbackJSON
								feedbackConfigJson:configDict
										uploadPath:@""
									loggerDelegate:self
								  feedbackDelegate:self];

}

- (NSString*)getConnectionType {
	Reachability *reachability = [Reachability reachabilityForInternetConnection];
	NetworkStatus status = [reachability currentReachabilityStatus];

	if (status == NotReachable) {
		return @"none";
	} else if (status == ReachableViaWiFi) {
		return @"WIFI";
	} else if (status == ReachableViaWWAN) {
		return @"mobile";
	}

	return @"error";
}

#pragma mark - PsiphonTunnelLoggerDelegate

- (void)onDiagnosticMessage:(NSString * _Nonnull)message
			  withTimestamp:(NSString * _Nonnull)timestamp {
	dispatch_async(self->workQueue, ^{
		NSString *log = [NSString stringWithFormat:@"FeedbackUpload: %@", message];
		DiagnosticEntry *d = [DiagnosticEntry msg:log andTimestamp:[PsiphonData iso8601ToDate:timestamp]];
		[[PsiphonData sharedInstance] addDiagnosticEntry:d];
	});
}

#pragma mark - PsiphonTunnelFeedbackDelegate

- (void)sendFeedbackCompleted:(NSError * _Nullable)err {
	dispatch_async(self->workQueue, ^{
		assert([self->pendingUploads count] > 0);

		if (err != nil) {
			DiagnosticEntry *d = [DiagnosticEntry msg:[NSString stringWithFormat:@"FeedbackUpload: failed %@", err]];
			[[PsiphonData sharedInstance] addDiagnosticEntry:d];
		} else {
			DiagnosticEntry *d = [DiagnosticEntry msg:@"FeedbackUpload: success"];
			[[PsiphonData sharedInstance] addDiagnosticEntry:d];
		}

		// Check if the upload completed because it was cancelled and should be retried.
		if (self->uploadPaused == FALSE) {
			[self->pendingUploads removeObjectAtIndex:0];
		}

		if ([self->pendingUploads count] == 0) {
			self->psiphonTunnelFeedback = nil;
		} else {
			[self startSendingFeedback];
		}
	});
}

@end
