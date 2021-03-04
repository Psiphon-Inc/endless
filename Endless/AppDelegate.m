/*
 * Copyright (c) 2017, Psiphon Inc.
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
 * Endless
 * Copyright (c) 2014-2015 joshua stein <jcs@jcs.org>
 *
 * See LICENSE file for redistribution terms.
 */

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <AudioToolbox/AudioServices.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CFSocket.h>

#import "AppDelegate.h"
#import "Bookmark.h"
#import "HTTPSEverywhere.h"
#import "Privacy.h"
#import "PsiphonData.h"
#import "PsiphonClientCommonLibraryHelpers.h"
#import "UpstreamProxySettings.h"

NSString* _Nonnull const clearAllWhenBackgroundedUserDefaultsKey = @"clearAllWhenBackgrounded";

@implementation AppDelegate {
	// Array of home pages from the handshake.
	// We will pick only one URL from this array
	// when it's time to open a home page
	NSMutableArray *_handshakeHomePages;

	SystemSoundID _notificationSound;
	Reachability *_reachability;
	UIAlertController *authAlertController;
	NSTimer *_appActiveTimer;
	NSInteger _lastActiveTickTime;
}

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	[JAHPAuthenticatingHTTPProtocol setDelegate:self];
	[JAHPAuthenticatingHTTPProtocol start];


	[self initializeDefaults];

	self.hstsCache = [HSTSCache retrieve];
	[CookieJar syncCookieAcceptPolicy];
	[Bookmark retrieveList];
	self.sslCertCache = [[NSCache alloc] init];

	self.certificateAuthentication = [[CertificateAuthentication alloc] init];

	NSURL *audioPath = [[NSBundle mainBundle] URLForResource:@"blip1" withExtension:@"wav"];
	AudioServicesCreateSystemSoundID((__bridge CFURLRef)audioPath, &_notificationSound);

	self.socksProxyPort = 0;
	self.httpProxyPort = 0;
	
	self.psiphonTunnel = [PsiphonTunnel newPsiphonTunnel:self];

	_reachability = [Reachability reachabilityForInternetConnection];

	BOOL isOnboarding = ![[NSUserDefaults standardUserDefaults] boolForKey:kHasBeenOnboardedKey];
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.rootViewController = [[WebViewController alloc] init];
	self.window.rootViewController.restorationIdentifier = @"WebViewController";
	[(WebViewController*)self.window.rootViewController setResumePsiphonStart:isOnboarding];
	[(WebViewController*)self.window.rootViewController setShowTutorial:isOnboarding];

	[DownloadHelper deleteDownloadsDirectory];

	return YES;
}

- (void)reloadOnboardingForl10n {
	WebViewController *newOnboarding = [[WebViewController alloc] init];
	newOnboarding.restorationIdentifier = @"WebViewController";
	newOnboarding.resumePsiphonStart = YES;
	newOnboarding.showTutorial = YES;

	[self changeRootViewController:newOnboarding];
}

// From https://gist.github.com/gimenete/53704124583b5df3b407
- (void)changeRootViewController:(UIViewController*)viewController {
	if (!self.window.rootViewController) {
		self.window.rootViewController = viewController;
		return;
	}

	UIViewController *prevViewController = self.window.rootViewController;

	UIView *snapShot = [self.window snapshotViewAfterScreenUpdates:YES];
	[viewController.view addSubview:snapShot];

	self.window.rootViewController = viewController;

	[prevViewController dismissViewControllerAnimated:NO completion:^{
		// Remove the root view in case it is still showing
		[prevViewController.view removeFromSuperview];
	}];

	[UIView animateWithDuration:.3 animations:^{
		snapShot.layer.opacity = 0;
		snapShot.layer.transform = CATransform3DMakeScale(1.5, 1.5, 1.5);
	} completion:^(BOOL finished) {
		[snapShot removeFromSuperview];
	}];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	// Migrate old cookie policy values
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

	// Casting nil to 0 is OK here:
	int lastBuildNumber = (int)[defaults integerForKey:kBuildNumber];
	[CookieJar migrateOldValuesForVersion:lastBuildNumber];

	// Store build number for any future references
	int buildNumber = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] intValue];
	[defaults setInteger:buildNumber forKey:kBuildNumber];

	// Enable background audio playback
	AVAudioSession *audioSession = [AVAudioSession sharedInstance];
	BOOL ok;
	NSError *setCategoryError = nil;
	ok = [audioSession setCategory:AVAudioSessionCategoryPlayback
							 error:&setCategoryError];
	if (!ok) {
#ifdef DEBUG
		NSLog(@"AVAudioSession setCategoryError=%@", setCategoryError);
#endif
	}

	[self.window makeKeyAndVisible];
	return YES;
}

- (void) startPsiphon {
	dispatch_async(dispatch_get_main_queue(), ^{
		if(_handshakeHomePages && [_handshakeHomePages count] > 0) {
			[_handshakeHomePages removeAllObjects];
		}
		// Start the Psiphon tunnel
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			if( ! [self.psiphonTunnel start:NO] ) {
				self.psiphonConectionState = ConnectionStateDisconnected;
				[self notifyPsiphonConnectionState];
			}
		});
	});
}


- (void)applicationWillResignActive:(UIApplication *)application
{
	[application ignoreSnapshotOnNextApplicationLaunch];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{

	if (![self areTesting]) {
		[[self hstsCache] persist];
	}

	if ([self clearAllWhenBackgrounded]) {
		[[self webViewController] removeAllTabsForBackgrounded];
		[Privacy clearWebsiteData];
	}

	if(_appActiveTimer && [_appActiveTimer isValid]) {
		// make timer selector get called on its target immediately
		[_appActiveTimer fire];
		[_appActiveTimer invalidate];
		_appActiveTimer = nil;
	}

	[application ignoreSnapshotOnNextApplicationLaunch];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kHasBeenOnboardedKey]) {
		[self startIfNeeded];
	}
	// If the key kAppActiveTimeSinceLastHomePage exists
	// then we opened a home page at least once
	// App active timer should be started right after
	// the app becomes active in that case
	BOOL shouldStartTimer = ([[NSUserDefaults standardUserDefaults] objectForKey:kAppActiveTimeSinceLastHomePage] != nil);
	if(shouldStartTimer) {
		[self startAppActiveTimer];
	}
}

- (void) startAppActiveTimer {
	if (!_appActiveTimer || ![_appActiveTimer isValid]) {
		_lastActiveTickTime = (NSInteger)CACurrentMediaTime();
		_appActiveTimer = [NSTimer scheduledTimerWithTimeInterval:APP_ACTIVE_TIMER_INTERVAL_SECONDS
														   target:self
														 selector:@selector(onAppActiveTimerTick:)
														 userInfo:nil
														  repeats:YES];
	}
	// make timer selector get called on its target immediately once
	[_appActiveTimer fire];
}

-(void)startIfNeeded {
	BOOL needStart = false;

	// Auto start if not connected
	if (self.psiphonConectionState != ConnectionStateConnected) {
		needStart = true;
	} else if (self.socksProxyPort > 0) {
		// check if SOCKS local proxy is still accessible

		CFSocketRef sockfd;
		sockfd = CFSocketCreate(NULL, AF_INET, SOCK_STREAM, IPPROTO_TCP,0, NULL,NULL);
		struct sockaddr_in servaddr;
		memset(&servaddr, 0, sizeof(servaddr));
		servaddr.sin_len = sizeof(servaddr);
		servaddr.sin_family = AF_INET;
		servaddr.sin_port = htons([self socksProxyPort]);
		inet_pton(AF_INET, [@"127.0.0.1" cStringUsingEncoding:NSUTF8StringEncoding], &servaddr.sin_addr);
		CFDataRef connectAddr = CFDataCreate(NULL, (unsigned char *)&servaddr, sizeof(servaddr));
		if (CFSocketConnectToAddress(sockfd, connectAddr, 1) != kCFSocketSuccess) {
			needStart = true;
		}
		CFSocketInvalidate(sockfd);
		CFRelease(sockfd);
		CFRelease(connectAddr);

	} else {
		needStart = true;
	}

	if(needStart) {
		if (_reachability.currentReachabilityStatus == NotReachable) {
			self.psiphonConectionState = ConnectionStateWaitingForNetwork;
		} else {
			self.psiphonConectionState = ConnectionStateConnecting;
		}
		[self notifyPsiphonConnectionState];
		[self startPsiphon];
	}
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	/* this definitely ends our sessions */
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		[self.psiphonTunnel stop];
	});

	// Notifications
	[[NSNotificationCenter defaultCenter] removeObserver:self name:kReachabilityChangedNotification object:nil];

	// Downloads
	[DownloadHelper deleteDownloadsDirectory];

	// OCSPCache
	if (![self clearAllWhenBackgrounded]) {
		[self.certificateAuthentication persist];
	}

	[application ignoreSnapshotOnNextApplicationLaunch];
}

- (BOOL)application:(UIApplication *)application shouldRestoreApplicationState:(NSCoder *)coder
{
	if ([self areTesting])
		return NO;

	/* if we tried last time and failed, the state might be corrupt */
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	if ([userDefaults objectForKey:STATE_RESTORE_TRY_KEY] != nil) {
		NSLog(@"previous startup failed, not restoring application state");
		[userDefaults removeObjectForKey:STATE_RESTORE_TRY_KEY];
		return NO;
	}
	else
		[userDefaults setBool:YES forKey:STATE_RESTORE_TRY_KEY];

	[userDefaults synchronize];

	return YES;
}

- (BOOL)application:(UIApplication *)application shouldSaveApplicationState:(NSCoder *)coder
{
	if ([self areTesting])
		return NO;

	if ([self clearAllWhenBackgrounded]) {
		return NO;
	}

	return YES;
}

- (void)initializeDefaults
{
	[PsiphonClientCommonLibraryHelpers initializeDefaultsForPlistsFromRoot:@"Root.inApp"];

	_searchEngines = [NSMutableDictionary dictionaryWithContentsOfFile:[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"SearchEngines.plist"]];
}

- (BOOL)areTesting
{
	return (NSClassFromString(@"XCTestProbe") != nil);
}

- (void)scheduleRunningTunnelServiceRestart {
	self.psiphonConectionState = ConnectionStateConnecting;
	[self notifyPsiphonConnectionState];
	[self startPsiphon];
}

+ (AppDelegate *)sharedAppDelegate {
	__block AppDelegate *delegate;
	if([NSThread isMainThread]) {
		delegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
	} else {
		dispatch_sync(dispatch_get_main_queue(), ^{
			delegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
		});
	}
	return delegate;
}

- (void)onAppActiveTimerTick:(NSTimer *)timer {
	NSInteger elapsedInterval = (NSInteger)CACurrentMediaTime() - _lastActiveTickTime;
	if(elapsedInterval > 0) {
		NSInteger currentAppActiveTime = [[NSUserDefaults standardUserDefaults] integerForKey:kAppActiveTimeSinceLastHomePage];
		if(currentAppActiveTime < 0) {
			// Guard against defaults corruption.
			// We care less if the number is too large, worst case we will prematurely
			// open a home page on the next reconnect.
			currentAppActiveTime = 0;
		}
		NSInteger newAppActiveTime;

		if(!__builtin_add_overflow(currentAppActiveTime, elapsedInterval, &newAppActiveTime)){
			// no overlow, write new value to defaults
			[[NSUserDefaults standardUserDefaults] setInteger:(newAppActiveTime) forKey:kAppActiveTimeSinceLastHomePage];
		}
		// do nothing in case of overflow
	}

	_lastActiveTickTime = (NSInteger)CACurrentMediaTime();
}

// MARK: TunneledAppDelegate protocol implementation

- (NSString *)getPsiphonConfig {
	NSFileManager *fileManager = [NSFileManager defaultManager];

	NSString *bundledConfigPath = [[[ NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"psiphon_config"];
	if(![fileManager fileExistsAtPath:bundledConfigPath]) {
		NSLog(@"Config file not found. Aborting now.");
		abort();
	}

	//Read in psiphon_config JSON
	NSData *jsonData = [fileManager contentsAtPath:bundledConfigPath];
	NSError *e = nil;
	NSDictionary *readOnly = [NSJSONSerialization JSONObjectWithData: jsonData options: kNilOptions error: &e];

	NSMutableDictionary *mutableConfigCopy = [readOnly mutableCopy];

	if(e) {
		NSLog(@"Failed to parse config JSON. Aborting now.");
		abort();
	}

	NSString *selectedRegionCode = [[RegionAdapter sharedInstance] getSelectedRegion].code;
	mutableConfigCopy[@"EgressRegion"] = selectedRegionCode;

	NSString *upstreamProxyUrl = [[UpstreamProxySettings sharedInstance] getUpstreamProxyUrl];
	if ([upstreamProxyUrl length] > 0) {
		mutableConfigCopy[@"UpstreamProxyURL"] = upstreamProxyUrl;
	}

	if ([[UpstreamProxySettings sharedInstance] getUseCustomHeaders]) {
		NSDictionary *customHeaders = [[UpstreamProxySettings sharedInstance] getUpstreamProxyCustomHeaders];
		if ([customHeaders count] > 0) {
			mutableConfigCopy[@"CustomHeaders"] = customHeaders;
		}
	}

	BOOL disableTimeouts = [[NSUserDefaults standardUserDefaults] boolForKey:kDisableTimeouts];
	if (disableTimeouts) {
		mutableConfigCopy[@"TunnelConnectTimeoutSeconds"] = 0;
		mutableConfigCopy[@"TunnelPortForwardDialTimeoutSeconds"] = 0;
		mutableConfigCopy[@"TunnelSshKeepAliveProbeTimeoutSeconds"] = 0;
		mutableConfigCopy[@"TunnelSshKeepAlivePeriodicTimeoutSeconds"] = 0;
		mutableConfigCopy[@"FetchRemoteServerListTimeoutSeconds"] = 0;
		mutableConfigCopy[@"PsiphonApiServerTimeoutSeconds"] = 0;
		mutableConfigCopy[@"FetchRoutesTimeoutSeconds"] = 0;
		mutableConfigCopy[@"HttpProxyOriginServerTimeoutSeconds"] = 0;
	}

	mutableConfigCopy[@"ClientVersion"] = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];

	mutableConfigCopy[@"EmitDiagnosticNotices"] = [NSNumber numberWithBool:TRUE];

	jsonData = [NSJSONSerialization dataWithJSONObject:mutableConfigCopy
											   options:0 // non-pretty printing
												 error:&e];
	if (e) {
		NSLog(@"Failed to create JSON data from config object. Aborting now.");
		abort();
	}
	return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (NSString *) getEmbeddedServerEntries {
    // Read in the embedded server entries
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *bundledEmbeddedServerEntriesPath = [[[ NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"embedded_server_entries"];
    NSString *embeddedServerEntries = [[NSString alloc] initWithData:[fileManager contentsAtPath:bundledEmbeddedServerEntriesPath] encoding:NSASCIIStringEncoding];
    if(!embeddedServerEntries) {
        NSLog(@"Embedded server entries file not found. Aborting now.");
        abort();
        return NULL;
    }

    return embeddedServerEntries;
}

- (void) onAvailableEgressRegions:(NSArray *)regions {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[RegionAdapter sharedInstance] onAvailableEgressRegions:regions];
	});
}

- (void)onDiagnosticMessage:(NSString *)message withTimestamp:(NSString *)timestamp {
	dispatch_async(dispatch_get_main_queue(), ^{
#ifdef TRACE
		NSLog(@"onDiagnosticMessage: %@", message);
#endif
		DiagnosticEntry *d =
			[DiagnosticEntry msg:message
					andTimestamp:[PsiphonData iso8601ToDate:timestamp]];
		[[PsiphonData sharedInstance] addDiagnosticEntry:d];
	});
}

- (void) onListeningSocksProxyPort:(NSInteger)port {
	dispatch_async(dispatch_get_main_queue(), ^{
		[JAHPAuthenticatingHTTPProtocol resetSharedDemux];
		self.socksProxyPort = port;
	});
}


- (void) onListeningHttpProxyPort:(NSInteger)port {
	dispatch_async(dispatch_get_main_queue(), ^{
		[JAHPAuthenticatingHTTPProtocol resetSharedDemux];
		self.httpProxyPort = port;
	});
}

- (void) onConnecting {
	dispatch_async(dispatch_get_main_queue(), ^{
		if (_reachability.currentReachabilityStatus == NotReachable) {
			self.psiphonConectionState = ConnectionStateWaitingForNetwork;
		} else {
			self.psiphonConectionState = ConnectionStateConnecting;
		}
		[self notifyPsiphonConnectionState];
	});
}

- (void) onConnected {
	dispatch_async(dispatch_get_main_queue(), ^{
		self.psiphonConectionState = ConnectionStateConnected;
		[self notifyPsiphonConnectionState];

		NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

		if ([userDefaults boolForKey:@"vibrate_notification"]) {
			AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
		}

		if ([userDefaults boolForKey:@"sound_notification"]) {
			AudioServicesPlaySystemSound (_notificationSound);
		}

		// If kAppActiveTimeSinceLastHomePage doesn't exist then it is probably the very first app run
		// and we should show a home page
		BOOL shouldOpenHomePage = ([[NSUserDefaults standardUserDefaults] objectForKey:kAppActiveTimeSinceLastHomePage] == nil);
		NSLog(@"shouldOpenHomePage == %@ , kAppActiveTimeSinceLastHomePage exists == %@", shouldOpenHomePage ? @"YES" : @"NO", !shouldOpenHomePage ? @"YES" : @"NO");


		if(!shouldOpenHomePage) {
			// Check if enough uptime has passed and we should show a home page
			NSInteger activeTime = [[NSUserDefaults standardUserDefaults] integerForKey:kAppActiveTimeSinceLastHomePage];

			// If activeTime is negative then defaults are probably corrupted
			// Fix it by showing a home page which will also reset the corrupted value to 0
			shouldOpenHomePage = (activeTime < 0 || activeTime > APP_ACTIVE_TIME_BEFORE_NEXT_HOMEPAGE_SECONDS);
#ifdef TRACE
			NSLog(@"shouldOpenHomePage == %@, App active time == %ld, APP_ACTIVE_TIME_BEFORE_NEXT_HOMEPAGE_SECONDS == %d", shouldOpenHomePage ? @"YES" : @"NO", activeTime, APP_ACTIVE_TIME_BEFORE_NEXT_HOMEPAGE_SECONDS);
#endif
		}

		if(!shouldOpenHomePage) {
			// Check if there are any tabs. If none then we should show a home page
			shouldOpenHomePage = ([[[self webViewController] webViewTabs] count]== 0);
#ifdef TRACE
			NSLog(@"shouldOpenHomePage == %@, [[[self webViewController] webViewTabs] count]== %lu", shouldOpenHomePage ? @"YES" : @"NO", (unsigned long)[[[self webViewController] webViewTabs] count]);
#endif
		}

		if(shouldOpenHomePage) {
			if(_handshakeHomePages && [_handshakeHomePages count] > 0) {
				// pick single URL from the handshake
				NSString *selectedHomePage = _handshakeHomePages[0];

				[self.webViewController openPsiphonHomePage: selectedHomePage];

				// If the key kAppActiveTimeSinceLastHomePage doesn't exist
				// we need to start app active timer
				// after opening a home page.
				// Otherwise it should be started when the app becomes active
				// in the - (void)applicationDidBecomeActive:(UIApplication *)application
				BOOL shouldStartTimer = ([[NSUserDefaults standardUserDefaults] objectForKey:kAppActiveTimeSinceLastHomePage] == nil);

				// Reset active time since last home page once we open a homepage
				// That will also create kAppActiveTimeSinceLastHomePage if it didn't exist
				[[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kAppActiveTimeSinceLastHomePage];

				if(shouldStartTimer) {
					[self startAppActiveTimer];
				}
			}
		} else {
			// Check if all present tabs are from restoration
			// In that case we need to focus one with the restoration index
			// to make sure it is switched to and refreshed
			BOOL shouldFocusRestorationTab = YES;
			int tabIndex;
			for (tabIndex = 0; tabIndex < [[[self webViewController] webViewTabs] count]; tabIndex++) {
				WebViewTab* wvt = [[self webViewController] webViewTabs][tabIndex];
				if (!wvt.isRestoring) {
					shouldFocusRestorationTab = NO;
					break;
				}
			}

			if(shouldFocusRestorationTab) {
				NSNumber *rti = [[self webViewController] tabIndexFromRestoration];
				if (rti != nil) {
					tabIndex = [rti intValue];
					[[self webViewController] focusTabWithIndex: tabIndex andRefresh:NO animated:NO];
				}
			}
		}
	});
}

- (void) onHomepage:(NSString *)url {
	if([url length] == 0) {
		return;
	}

	if (!_handshakeHomePages) {
		_handshakeHomePages = [NSMutableArray new];
	}

	if([_handshakeHomePages indexOfObject:url] == NSNotFound) {
		[_handshakeHomePages addObject:url];
	}
}

- (void) reloadAndOpenSettings {
	[[RegionAdapter sharedInstance] reloadTitlesForNewLocalization];

	// iterate existing tabs, remove them from superview
	// and re-add to the new instance of WebViewController

	WebViewController* prevWebViewController = self.webViewController;
	NSArray * wvTabs = [prevWebViewController webViewTabs];

	WebViewTab* focusedTab = [prevWebViewController curWebViewTab];

	WebViewController* wvc = [[WebViewController alloc] init];
	wvc.restorationIdentifier = @"WebViewController";
	[self changeRootViewController:wvc];

	for (WebViewTab *wvt in wvTabs) {
		BOOL isCurrentTab = NO;

		// make sure tabs get added zoomed normal
		[wvt zoomNormal];

		[wvt.viewHolder removeFromSuperview];
		if (focusedTab == wvt) {
			isCurrentTab = YES;
		}
		// Reload tab's localizables
		[wvt initLocalizables];

		[wvc addWebViewTab:wvt andSetCurrent:isCurrentTab];
	}

	// Ensure the navigation bar URL field is filled in correctly.
	[wvc updateSearchBarDetails];

	[prevWebViewController dismissViewControllerAnimated:NO completion:^{
		// Remove the root view in case it is still showing
		[prevWebViewController.view removeFromSuperview];
	}];

	[self notifyPsiphonConnectionState];
	[self.webViewController setOpenSettingImmediatelyOnViewDidAppear:YES];
}

- (void)notifyPsiphonConnectionState {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter]
		 postNotificationName:kPsiphonConnectionStateNotification
		 object:self
		 userInfo:@{kPsiphonConnectionState: @(self.psiphonConectionState)}];
	});
}

- (void)onInternetReachabilityChanged:(Reachability*)currentReachability {
	if([currentReachability currentReachabilityStatus] == NotReachable) {
		if(self.psiphonConectionState != ConnectionStateDisconnected) {
			self.psiphonConectionState = ConnectionStateWaitingForNetwork;
			[self notifyPsiphonConnectionState];
		}
	} else {
		self.psiphonConectionState = ConnectionStateConnecting;
	}
}

// MARK: JAHPAuthenticatingHTTPProtocol delegate methods
#ifdef TRACE
- (void)authenticatingHTTPProtocol:(JAHPAuthenticatingHTTPProtocol *)authenticatingHTTPProtocol logWithFormat:(NSString *)format arguments:(va_list)arguments {
	NSLog(@"[JAHPAuthenticatingHTTPProtocol] %@", [[NSString alloc] initWithFormat:format arguments:arguments]);
}
#endif

- (BOOL)authenticatingHTTPProtocol:( JAHPAuthenticatingHTTPProtocol *)authenticatingHTTPProtocol canAuthenticateAgainstProtectionSpace:( NSURLProtectionSpace *)protectionSpace {
	return ([protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPDigest]
			|| [protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]);
}

- (JAHPDidCancelAuthenticationChallengeHandler)authenticatingHTTPProtocol:( JAHPAuthenticatingHTTPProtocol *)authenticatingHTTPProtocol didReceiveAuthenticationChallenge:( NSURLAuthenticationChallenge *)challenge {
	NSURLCredential *nsuc;

	/* if we have existing credentials for this realm, try it first */
	if ([challenge previousFailureCount] == 0) {
		NSDictionary *d = [[NSURLCredentialStorage sharedCredentialStorage] credentialsForProtectionSpace:[challenge protectionSpace]];
		if (d != nil) {
			for (id u in d) {
				nsuc = [d objectForKey:u];
				break;
			}
		}
	}

	/* no credentials, prompt the user */
	if (nsuc == nil) {
		dispatch_async(dispatch_get_main_queue(), ^{
			authAlertController = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"HTTP_AUTH_TITLE", nil, [NSBundle mainBundle], @"Authentication Required", @"HTTP authentication alert title") message:@"" preferredStyle:UIAlertControllerStyleAlert];

			if ([[challenge protectionSpace] realm] != nil && ![[[challenge protectionSpace] realm] isEqualToString:@""])
				[authAlertController setMessage:[NSString stringWithFormat:@"%@: \"%@\"", [[challenge protectionSpace] host], [[challenge protectionSpace] realm]]];
			else
				[authAlertController setMessage:[[challenge protectionSpace] host]];

			[authAlertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
				textField.placeholder = NSLocalizedStringWithDefaultValue(@"HTTP_AUTH_USER_NAME", nil, [NSBundle mainBundle], @"User Name", "HTTP authentication alert user name input title");
			}];

			[authAlertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
				textField.placeholder = NSLocalizedStringWithDefaultValue(@"HTTP_AUTH_PASSWORD", nil, [NSBundle mainBundle], @"Password", @"HTTP authentication alert password input title");
				textField.secureTextEntry = YES;
			}];

			[authAlertController addAction:[UIAlertAction actionWithTitle:NSLocalizedStringWithDefaultValue(@"CANCEL_ACTION", nil, [NSBundle mainBundle], @"Cancel", @"Cancel action") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
				[[challenge sender] cancelAuthenticationChallenge:challenge];
				[authenticatingHTTPProtocol.client URLProtocol:authenticatingHTTPProtocol didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{ ORIGIN_KEY: @YES }]];
			}]];

			[authAlertController addAction:[UIAlertAction actionWithTitle:NSLocalizedStringWithDefaultValue(@"HTTP_AUTH_LOG_IN", nil, [NSBundle mainBundle], @"Log In", @"HTTP authentication alert log in button action") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
				UITextField *login = authAlertController.textFields.firstObject;
				UITextField *password = authAlertController.textFields.lastObject;

				NSURLCredential *nsuc = [[NSURLCredential alloc] initWithUser:[login text] password:[password text] persistence:NSURLCredentialPersistenceForSession];

				// We only want one set of credentials per [challenge protectionSpace]
				// in case we stored incorrect credentials on the previous login attempt
				// Purge stored credentials for the [challenge protectionSpace]
				// before storing new ones.
				// Based on a snippet from http://www.springenwerk.com/2008/11/i-am-currently-building-iphone.html

				NSDictionary *credentialsDict = [[NSURLCredentialStorage sharedCredentialStorage] credentialsForProtectionSpace:[challenge protectionSpace]];
				if ([credentialsDict count] > 0) {
					NSEnumerator *userNameEnumerator = [credentialsDict keyEnumerator];
					id userName;

					// iterate over all usernames, which are the keys for the actual NSURLCredentials
					while (userName = [userNameEnumerator nextObject]) {
						NSURLCredential *cred = [credentialsDict objectForKey:userName];
						if(cred) {
							[[NSURLCredentialStorage sharedCredentialStorage] removeCredential:cred forProtectionSpace:[challenge protectionSpace]];
						}
					}
				}

				[[NSURLCredentialStorage sharedCredentialStorage] setCredential:nsuc forProtectionSpace:[challenge protectionSpace]];

				[authenticatingHTTPProtocol resolvePendingAuthenticationChallengeWithCredential:nsuc];
			}]];

			[[[AppDelegate sharedAppDelegate] webViewController] presentViewController:authAlertController animated:YES completion:nil];
		});
	}
	else {
		[[NSURLCredentialStorage sharedCredentialStorage] setCredential:nsuc forProtectionSpace:[challenge protectionSpace]];
		[authenticatingHTTPProtocol resolvePendingAuthenticationChallengeWithCredential:nsuc];
	}

	return nil;

}

- (void)authenticatingHTTPProtocol:( JAHPAuthenticatingHTTPProtocol *)authenticatingHTTPProtocol didCancelAuthenticationChallenge:( NSURLAuthenticationChallenge *)challenge {
	if(authAlertController) {
		if (authAlertController.isViewLoaded && authAlertController.view.window) {
			[authAlertController dismissViewControllerAnimated:NO completion:nil];
		}
	}
}

#pragma mark - User defaults

- (BOOL)clearAllWhenBackgrounded {
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	return [userDefaults boolForKey:clearAllWhenBackgroundedUserDefaultsKey];
}

@end
