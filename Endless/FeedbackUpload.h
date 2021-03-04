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

#import <Foundation/Foundation.h>
#import <PsiphonTunnel/PsiphonTunnel.h>
#import <PsiphonClientCommonLibrary/PsiphonClientCommonLibraryConstants.h>

NS_ASSUME_NONNULL_BEGIN

/// FeedbackUpload facilitates securely uploading user feedback to Psiphon Inc.
@interface FeedbackUpload : NSObject <PsiphonTunnelFeedbackDelegate, PsiphonTunnelLoggerDelegate>

/// Use initWithConnectionState.
- (instancetype)init NS_UNAVAILABLE;

/// Intialize feedback upload instance.
/// @param state Initial connection state.
- (id)initWithConnectionState:(ConnectionState)state;

/// Securely upload the given user feedback to Psiphon Inc.
/// @note If a feedback upload operation is already ongoing, then the feedback will be uploaded when the previous upload completes.
/// @param selectedThumbIndex User survey response.
/// @param comments User feedback comment.
/// @param email User email address.
/// @param uploadDiagnostics If true, the user has opted in to including diagnostics with their feedback and diagnostics will be
/// included in uploaded feedback. Otherwise, diagnostics will be omitted.
- (void)uploadFeedbackWithSelectedThumbIndex:(NSInteger)selectedThumbIndex
									comments:(NSString*)comments
									   email:(NSString*)email
						   uploadDiagnostics:(BOOL)uploadDiagnostics;

/// Inform the FeedbackUpload instance of a connection state change. This function should be called whenever the app's connection
/// state changes, so ongoing uploads can be paused, restarted, or reconfigured, when required.
/// @param state New connection state.
- (void)setConnectionState:(ConnectionState)state;

@end

NS_ASSUME_NONNULL_END
