//
//  LEANSimulator.m
//  GoNativeIOS
//
//  Created by Weiyin He on 8/21/14.
//  Copyright (c) 2014 GoNative.io LLC. All rights reserved.
//

#import "LEANSimulator.h"
#import "LEANAppDelegate.h"
#import "LEANAppConfig.h"
#import "LEANLoginManager.h"
#import "LEANPushManager.h"
#import "LEANUrlInspector.h"
#import "LEANWebViewPool.h"
#import "LEANConfigUpdater.h"

static NSString * const simulatorConfigTemplate = @"https://gonative.io/api/simulator/appConfig/%@";

@interface LEANSimulator () <UIAlertViewDelegate>
@property NSURLSessionDownloadTask *downloadTask;
@property NSString *simulatePublicKey;
@property UIWindow *simulatorBarWindow;
@property UIButton *simulatorBarButton;
@property UIAlertView *progressAlert;
@property NSTimer *showBarTimer;
@property NSTimer *spinTimer;
@property NSInteger state;
@end


@implementation LEANSimulator

+ (LEANSimulator *)sharedSimulator
{
    static LEANSimulator *sharedSimulator;
    
    @synchronized(self)
    {
        if (!sharedSimulator){
            sharedSimulator = [[LEANSimulator alloc] init];
        }
        return sharedSimulator;
    }
}

+(BOOL)openURL:(NSURL *)url
{
    return [[LEANSimulator sharedSimulator] openURL:url];
}

-(BOOL)openURL:(NSURL*)url
{
    if (![[url scheme] isEqualToString:@"gonative.io"] || ![[url host] isEqualToString:@"gonative.io"]) {
        return NO;
    }
    
    NSArray *components = [url pathComponents];
    NSUInteger pos = [components indexOfObject:@"simulate" inRange:NSMakeRange(0, [components count] - 1)];
    if (pos == NSNotFound) {
        return NO;
    }
    
    
    self.simulatePublicKey = components[pos+1];
    if ([self.simulatePublicKey length] == 0) {
        return NO;
    }
    
    // check public key is all lowercase and 5-10 characters long
    NSCharacterSet *invalidCharacters = [[NSCharacterSet lowercaseLetterCharacterSet] invertedSet];
    if ([self.simulatePublicKey length] < 5 || [self.simulatePublicKey length] > 10 ||
        [self.simulatePublicKey rangeOfCharacterFromSet:invalidCharacters].location != NSNotFound) {
        NSLog(@"Invalid public key for simulator");
        return NO;
    }
    
    NSURL *configUrl = [NSURL URLWithString:[NSString stringWithFormat:simulatorConfigTemplate, self.simulatePublicKey]];
    [self showProgress];
    
    self.downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:configUrl completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
        
        if (error || [httpResponse statusCode] != 200 || !location) {
            NSLog(@"Error downloading config (status code %d) %@", [httpResponse statusCode],  error);
            
            NSString *message;
            if ([httpResponse statusCode] == 404) {
                message = @"Could not find application.";
            } else {
                message = @"Unable to load app. Check your internet connection and try again.";
            }
            
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error" message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [alert show];
            });
            [self cancel];
        }
        else {
            // parse json to make sure it's valid
            NSInputStream *inputStream = [NSInputStream inputStreamWithURL:location];
            [inputStream open];
            NSError *jsonError;
            id json = [NSJSONSerialization JSONObjectWithStream:inputStream options:0 error:&jsonError];
            if (jsonError) {
                NSLog(@"Invalid appConfig.json downloaded");
                [inputStream close];
                return;
            }
            [inputStream close];
            
            [LEANSimulator moveFileFrom:location to:[LEANSimulator tempConfigUrl]];
            
            NSURL *iconUrl = nil;
            if ([json isKindOfClass:[NSDictionary class]] && [json[@"styling"][@"icon"] isKindOfClass:[NSString class]]) {
                iconUrl = [NSURL URLWithString:json[@"styling"][@"icon"] relativeToURL:[NSURL URLWithString:@"https://gonative.io/"]];
            }
            
            if (iconUrl) {
                [self downloadAppIconFromUrl:iconUrl];
            } else {
                [self startspin];
            }
        }
    }];
    [self.downloadTask resume];
    
    return YES;
}

- (void)downloadAppIconFromUrl:(NSURL*)url
{
    self.downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
        if (error || [httpResponse statusCode] != 200 || !location) {
            NSLog(@"Error downloading app icon (status code %d) %@", [httpResponse statusCode],  error);
            [self startspin];
        } else {
            [LEANSimulator moveFileFrom:location to:[LEANSimulator tempIconUrl]];
            [self startspin];
        }
    }];
    
    [self.downloadTask resume];
}

- (void)startSimulation
{
    [LEANSimulator moveFileFrom:[LEANSimulator tempConfigUrl] to:[LEANAppConfig urlForSimulatorConfig]];
    [LEANSimulator moveFileFrom:[LEANSimulator tempIconUrl] to:[LEANAppConfig urlForSimulatorIcon]];
    [LEANSimulator reloadApplication];
    [LEANConfigUpdater registerEvent:@"simulate" data:@{@"publicKey": self.simulatePublicKey}];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"is_simulating"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)moveFileFrom:(NSURL*)source to:(NSURL*)destination
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtURL:destination error:nil];
    [fileManager moveItemAtURL:source toURL:destination error:nil];
}

+ (NSURL*)tempConfigUrl
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *dir = [[fileManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *url = [dir URLByAppendingPathComponent:@"appConfig.json"];
    [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return url;
}

+ (NSURL*)tempIconUrl
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *dir = [[fileManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *url = [dir URLByAppendingPathComponent:@"appIcon.image"];
    [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return url;
}

+ (void)checkStatus
{
    [[LEANSimulator sharedSimulator].showBarTimer invalidate];
    [LEANSimulator sharedSimulator].showBarTimer = nil;
    if ([LEANAppConfig sharedAppConfig].isSimulating) {
        [LEANSimulator sharedSimulator].showBarTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:[LEANSimulator sharedSimulator] selector:@selector(showSimulatorBar) userInfo:nil repeats:NO];
    } else {
        [[LEANSimulator sharedSimulator] hideSimulatorBar];
    }
}

+ (void)didChangeStatusBarOrientation
{
    [[LEANSimulator sharedSimulator] didChangeStatusBarOrientation];
    [[LEANSimulator sharedSimulator] hideSimulatorBar];
    [LEANSimulator checkStatus];
}

-(void)didChangeStatusBarOrientation
{
    [self hideSimulatorBar];
    [LEANSimulator checkStatus];
}

- (void)showSimulatorBar
{
    CGRect frame = [[UIApplication sharedApplication] statusBarFrame];
    CGSize statusBarSize = CGSizeMake(MAX(frame.size.height, frame.size.width),
                                      MIN(frame.size.height, frame.size.width));
    
    if (!self.simulatorBarWindow) {
        self.simulatorBarWindow = [[UIWindow alloc] initWithFrame:frame];
        self.simulatorBarWindow.windowLevel = UIWindowLevelStatusBar + 1;
        [self.simulatorBarWindow setRootViewController:[UIViewController alloc]];
    }
    
    BOOL wasHidden = self.simulatorBarWindow.hidden;
    if (wasHidden) {
        self.simulatorBarWindow.alpha = 0;
    }
    
    self.simulatorBarWindow.hidden = [UIApplication sharedApplication].statusBarHidden;
    
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    if (orientation == UIInterfaceOrientationPortrait) {
        self.simulatorBarWindow.transform = CGAffineTransformIdentity;
    } else if (orientation == UIInterfaceOrientationLandscapeLeft) {
        self.simulatorBarWindow.transform = CGAffineTransformMakeRotation(-M_PI_2);
    } else if (orientation == UIInterfaceOrientationLandscapeRight) {
        self.simulatorBarWindow.transform = CGAffineTransformMakeRotation(M_PI_2);
    } else if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        self.simulatorBarWindow.transform = CGAffineTransformMakeRotation(M_PI);
    } else {
        self.simulatorBarWindow.transform = CGAffineTransformIdentity;
    }
    
    self.simulatorBarWindow.center = CGPointMake(frame.origin.x + (frame.size.width / 2),
                                     frame.origin.y + (frame.size.height / 2));
    CGRect windowBounds = self.simulatorBarWindow.bounds;
    windowBounds.size = statusBarSize;
    self.simulatorBarWindow.bounds = windowBounds;
    
    if (!self.simulatorBarButton) {
        self.simulatorBarButton = [UIButton buttonWithType:UIButtonTypeCustom];
        self.simulatorBarButton.backgroundColor = [UIColor colorWithRed:76.0/255 green:174.0/255 blue:76.0/255 alpha:1.0];
        self.simulatorBarButton.opaque = YES;
        self.simulatorBarButton.titleLabel.textColor = [UIColor whiteColor];
        self.simulatorBarButton.titleLabel.font = [UIFont systemFontOfSize:16.0];
        [self.simulatorBarButton setTitle:@"Tap to end GoNative.io simulator" forState:UIControlStateNormal];
        [self.simulatorBarButton addTarget:self action:@selector(buttonPressed:) forControlEvents:UIControlEventTouchUpInside];
        [self.simulatorBarWindow addSubview:self.simulatorBarButton];
    }
    self.simulatorBarButton.center = [self.simulatorBarWindow convertPoint:self.simulatorBarWindow.center fromWindow:nil];
    
    CGRect buttonBounds = self.simulatorBarButton.bounds;
    buttonBounds.size = statusBarSize;
    self.simulatorBarButton.bounds = buttonBounds;
    
    if (wasHidden) {
        [UIView animateWithDuration:0.6 animations:^{
            self.simulatorBarWindow.alpha = 1.0;
        }];
    }
}

- (void)hideSimulatorBar
{
    if (self.simulatorBarWindow) {
        self.simulatorBarWindow.hidden = YES;
    }
}

- (void) buttonPressed:(id)sender
{
    [self stopSimulation];
}

- (void)cancel
{
    [self hideProgress];
    [self.downloadTask cancel];
    self.downloadTask = nil;
    [self.spinTimer invalidate];
    self.spinTimer = nil;
}


+(void)reloadApplication
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[LEANLoginManager sharedManager] stopChecking];
        
        // clear cookies
        NSHTTPCookie *cookie;
        NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (cookie in [storage cookies]) {
            [storage deleteCookie:cookie];
        }
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // Change out AppConfig.
        LEANAppConfig *appConfig = [LEANAppConfig sharedAppConfig];
        [appConfig setupFromJsonFiles];
        
        // Rerun some app delegate stuff
        [(LEANAppDelegate*)[UIApplication sharedApplication].delegate configureApplication];
        
        // recreate the entire view controller heirarchy
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        window.rootViewController = [window.rootViewController.storyboard instantiateInitialViewController];
        
        // refresh some singletons
        if (appConfig.loginDetectionURL) {
            [[LEANLoginManager sharedManager] checkLogin];
        }
        
        [[LEANUrlInspector sharedInspector] setup];
        [[LEANWebViewPool sharedPool] setup];
        [[LEANPushManager sharedManager] sendRegistration];
    });
}

- (void)startspin
{
    self.state = 0;
    [self spin];
}

- (void)spin
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.state == 1) {
            self.progressAlert.message = @"Unpacking ...";
        } else if (self.state == 2) {
            self.progressAlert.message = @"Processing ...";
        } else if (self.state == 3) {
            self.progressAlert.message = @"Launch!";
        } else if (self.state >= 4) {
            [self hideProgress];
            [self startSimulation];
            return;
        }
        
        if (self.state < 3) {
            self.spinTimer = [NSTimer scheduledTimerWithTimeInterval:(0.5 + 1.0 * arc4random_uniform(1000)/1000.0) target:self selector:@selector(spin) userInfo:nil repeats:NO];
        } else {
            self.spinTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(spin) userInfo:nil repeats:NO];
        }
        
        self.state++;
    });
}

+(void)checkSimulatorSetting
{
    [[NSUserDefaults standardUserDefaults] synchronize];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"is_simulating"]) {
        if (![LEANAppConfig sharedAppConfig].isSimulating) {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"is_simulating"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    } else {
        if ([LEANAppConfig sharedAppConfig].isSimulating) {
            [[LEANSimulator sharedSimulator] stopSimulation];
        }
    }
}

-(void)stopSimulation
{
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *simulatorConfig = [LEANAppConfig urlForSimulatorConfig];
    [fileManager removeItemAtURL:simulatorConfig error:nil];
    [LEANSimulator reloadApplication];
    [LEANSimulator checkStatus];
}

-(void)showProgress
{
    self.progressAlert = [[UIAlertView alloc] initWithTitle:@"Simulator" message:@"Downloading your app" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles: nil];
    [self.progressAlert show];
}

- (void)hideProgress
{
    if (self.progressAlert) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressAlert dismissWithClickedButtonIndex:0 animated:NO];
        });
    }
}

- (void)alertView:(UIAlertView *)alertView willDismissWithButtonIndex:(NSInteger)buttonIndex
{
    [self cancel];
}


@end