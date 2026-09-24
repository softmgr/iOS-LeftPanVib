#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// =========================================================
// DEBUG SWITCH: Set to 1 to enable Clipboard Logging, 0 for Release
// =========================================================
#define ENABLE_DEBUG_LOGGING 0

// ---------------------------------------------------------
// CONFIGURATION (Constants for easy maintenance)
// ---------------------------------------------------------
#define kLPVPortraitZoneRatio (4.0 / 5.0)        
#define kLPVHuyaPortraitZoneRatio (4.0 / 5.0)    
#define kLPVLandscapeZoneWidth 50.0              
#define kLPVGestureStartVelocityThreshold -40.0
#define kLPVPortraitSuccessTranslationRatio 0.35     
#define kLPVHuyaPortraitSuccessTranslationRatio 0.20 
#define kLPVFallbackSuccessTranslation 100.0         
#define kLPVFallbackSuccessVelocity 300.0            
#define kLPVFallbackMinFlickTranslation 20.0         

static char kWindowHelperKey;

#pragma mark - Special App Whitelist

static BOOL isSpecialApp_Huya(void) {
    static BOOL isHuya = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        isHuya = [bundleID isEqualToString:@"com.yy.kiwi"];
    });
    return isHuya;
}

static BOOL isTiebaPBViewController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.baidu.tieba"]) return NO;
    
    NSString *vcClassStr = NSStringFromClass([vc class]);
    NSString *parentClassStr = vc.parentViewController ? NSStringFromClass([vc.parentViewController class]) : @"";
    
    if ([vcClassStr containsString:@"PBView"] || [parentClassStr containsString:@"PBView"] ||
        [vcClassStr containsString:@"FirstFloor"] || [parentClassStr containsString:@"FirstFloor"]) {
        return YES;
    }
    return NO;
}

#pragma mark - Custom Gesture Recognizer

@interface LPVReversePanGesture : UIPanGestureRecognizer
- (CGPoint)rawVelocityInView:(UIView *)view;
@end

@implementation LPVReversePanGesture
- (CGPoint)rawVelocityInView:(UIView *)view {
    return [super velocityInView:view];
}
- (CGPoint)translationInView:(UIView *)view {
    CGPoint t = [super translationInView:view];
    return CGPointMake(-t.x, t.y);
}
- (CGPoint)velocityInView:(UIView *)view {
    CGPoint v = [super velocityInView:view];
    return CGPointMake(-v.x, v.y);
}
@end

#pragma mark - Main Window Helper

@interface LeftPanWindowHelper : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, strong) LPVReversePanGesture *pan;
@property (nonatomic, weak) id systemTarget;
@property (nonatomic, assign) SEL systemAction;
@property (nonatomic, assign) BOOL useFallbackMode;
@end

@implementation LeftPanWindowHelper

- (instancetype)initWithWindow:(UIWindow *)window {
    self = [super init];
    if (self) {
        _window = window;
        _pan = [[LPVReversePanGesture alloc] initWithTarget:self action:@selector(handlePan:)];
        _pan.delegate = self;
        _pan.cancelsTouchesInView = YES;
        _pan.delaysTouchesBegan = YES;
        [window addGestureRecognizer:_pan];
    }
    return self;
}

#pragma mark - Universal Hierarchy Armor-Piercing & UI-Bot Logic

+ (UIViewController *)findTopViewController:(UIViewController *)root {
    if (!root) return nil;
    if (root.presentedViewController) {
        return [self findTopViewController:root.presentedViewController];
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        return [self findTopViewController:((UINavigationController *)root).visibleViewController];
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        return [self findTopViewController:((UITabBarController *)root).selectedViewController];
    }
    for (UIViewController *child in root.childViewControllers.reverseObjectEnumerator) {
        if (child.isViewLoaded && child.view.window && !child.view.hidden && child.view.alpha > 0.01) {
            return [self findTopViewController:child];
        }
    }
    return root;
}

+ (UINavigationController *)findValidNavigationControllerFor:(UIViewController *)vc {
    UIViewController *current = vc;
    while (current) {
        if (current.navigationController && current.navigationController.viewControllers.count > 1) {
            return current.navigationController;
        }
        if ([current isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)current;
            if (nav.viewControllers.count > 1) {
                return nav;
            }
        }
        current = current.parentViewController;
    }
    return nil;
}

+ (BOOL)canGoBack:(UIViewController *)topVC isLandscape:(BOOL)isLandscape {
    if (isLandscape) return YES;
    if (!topVC) return NO;
    
    if (isTiebaPBViewController(topVC)) return YES;
    
    // Safety Net: Always authorize WAWebView so UI-Bot can take over
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSString *vcClassStr = NSStringFromClass([topVC class]);
    if ([bundleID isEqualToString:@"com.tencent.xin"] && [vcClassStr containsString:@"WAWebView"]) {
        return YES; 
    }
    
    UIViewController *current = topVC;
    while (current) {
        if (current.navigationController && current.navigationController.viewControllers.count > 1) return YES;
        if ([current isKindOfClass:[UINavigationController class]]) {
            if (((UINavigationController *)current).viewControllers.count > 1) return YES;
        }
        if (current.presentingViewController && ![current isKindOfClass:[UITabBarController class]]) return YES;
        current = current.parentViewController;
    }
    return NO;
}

// -------------------------------------------------------------
// UI-BOT: Machine Vision Physical Touch Simulation
// -------------------------------------------------------------

+ (BOOL)executeActionOnView:(UIView *)view {
    BOOL executed = NO;
    // Method A: Standard UIControl Action Injection
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        if (control.allTargets.count > 0) {
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            executed = YES;
        }
    }
    // Method B: Gesture Recognizer Hijacking (for custom components)
    for (UIGestureRecognizer *gr in view.gestureRecognizers) {
        if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
            @try {
                NSArray *targets = [gr valueForKey:@"targets"];
                for (id targetObj in targets) {
                    id target = [targetObj valueForKey:@"target"];
                    SEL action = NSSelectorFromString([targetObj valueForKey:@"action"]);
                    if (target && [target respondsToSelector:action]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [target performSelector:action withObject:gr];
                        #pragma clang diagnostic pop
                        executed = YES;
                    }
                }
            } @catch (NSException *e) {}
        }
    }
    return executed;
}

+ (BOOL)clickWeChatBackButton:(UIWindow *)window {
    if (!window) return NO;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        
        if (view.hidden || view.alpha < 0.05) continue;
        
        NSString *cls = NSStringFromClass([view class]);
        // Strict scanning for UIBarButton components
        if ([cls containsString:@"Button"] || [cls containsString:@"BarItem"]) {
            CGRect absFrame = [view convertRect:view.bounds toView:nil];
            // Precision Targeting: Top-Left Corner Region
            if (absFrame.origin.x <= 100 && absFrame.origin.y <= 120 && absFrame.size.width > 0) {
                if ([self executeActionOnView:view]) {
                    return YES;
                }
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return NO;
}

+ (BOOL)clickWeChatCapsuleCloseButton:(UIWindow *)window {
    if (!window) return NO;
    CGFloat sWidth = window.bounds.size.width;
    UIView *targetView = nil;
    CGFloat maxX = -1;
    
    NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        
        if (view.hidden || view.alpha < 0.05) continue;
        
        NSString *cls = NSStringFromClass([view class]);
        if ([cls containsString:@"Button"] || [cls containsString:@"Capsule"]) {
            CGRect absFrame = [view convertRect:view.bounds toView:nil];
            // Precision Targeting: Top-Right Corner Region
            if (absFrame.origin.x >= sWidth - 150 && absFrame.origin.y <= 120 && absFrame.size.width > 0) {
                BOOL isActionable = NO;
                if ([view isKindOfClass:[UIControl class]] && ((UIControl *)view).allTargets.count > 0) isActionable = YES;
                for (UIGestureRecognizer *gr in view.gestureRecognizers) {
                    if ([gr isKindOfClass:[UITapGestureRecognizer class]]) isActionable = YES;
                }
                
                // We lock onto the right-most interactive element in the capsule (the 'O' button)
                if (isActionable) {
                    if (absFrame.origin.x > maxX) {
                        maxX = absFrame.origin.x;
                        targetView = view;
                    }
                }
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    
    if (targetView) {
        return [self executeActionOnView:targetView];
    }
    return NO;
}

+ (void)closeTopViewControllerHierarchy:(UIViewController *)topVC {
    UIViewController *current = topVC;
    while (current) {
        if (current.navigationController && current.navigationController.viewControllers.count > 1) {
            [current.navigationController popViewControllerAnimated:YES];
            return;
        }
        if ([current isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)current;
            if (nav.viewControllers.count > 1) {
                [nav popViewControllerAnimated:YES];
                return;
            }
        }
        if (current.presentingViewController && ![current isKindOfClass:[UITabBarController class]]) {
            [current dismissViewControllerAnimated:YES completion:nil];
            return;
        }
        current = current.parentViewController;
    }
}

// Targeted Interception: Isolate specific complex containers
+ (BOOL)isForbiddenAppViewController:(UIViewController *)vc {
    if (!vc) return NO;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSString *vcClassStr = NSStringFromClass([vc class]);
    
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        // ONLY block actual WeChat Mini Games (WAGame).
        // WAWebView is unleashed and handled via UI-Bot.
        if ([vcClassStr containsString:@"WAGame"]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)hasGameEngineView:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 10) return NO;
    if (view.hidden || view.alpha < 0.05) return NO;
    
    NSString *viewClassStr = NSStringFromClass([view class]);
    if ([viewClassStr containsString:@"Unity"] || 
        [viewClassStr containsString:@"EAGL"] || 
        [viewClassStr containsString:@"MTKView"] ||
        [viewClassStr containsString:@"FMetalView"] ||
        [viewClassStr containsString:@"XRNativeGame"] ||
        [viewClassStr containsString:@"OpenGL"]) {
        return YES;
    }
    
    for (UIView *subview in view.subviews) {
        if ([self hasGameEngineView:subview depth:depth + 1]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)isPortraitSupportedForWindow:(UIWindow *)window topVC:(UIViewController *)topVC {
    if (topVC) {
        UIInterfaceOrientationMask vcMask = topVC.supportedInterfaceOrientations;
        if (vcMask != 0 && !(vcMask & UIInterfaceOrientationMaskPortrait) && !(vcMask & UIInterfaceOrientationMaskPortraitUpsideDown)) {
            return NO; 
        }
    }
    UIInterfaceOrientationMask appMask = [[UIApplication sharedApplication] supportedInterfaceOrientationsForWindow:window];
    if (appMask != 0 && !(appMask & UIInterfaceOrientationMaskPortrait) && !(appMask & UIInterfaceOrientationMaskPortraitUpsideDown)) {
        return NO; 
    }
    NSArray *supportedOrientations = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UISupportedInterfaceOrientations"];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        NSArray *ipadOrientations = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UISupportedInterfaceOrientations~ipad"];
        if (ipadOrientations) supportedOrientations = ipadOrientations;
    }
    if (supportedOrientations && [supportedOrientations isKindOfClass:[NSArray class]]) {
        BOOL hasPortrait = NO;
        for (NSString *orientation in supportedOrientations) {
            if ([orientation isEqualToString:@"UIInterfaceOrientationPortrait"] ||
                [orientation isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) {
                hasPortrait = YES; break;
            }
        }
        if (!hasPortrait) return NO; 
    }
    return YES;
}

- (void)forcePortraitOrientation {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [[UIDevice currentDevice] setValue:@(UIDeviceOrientationUnknown) forKey:@"orientation"];
        [[UIDevice currentDevice] setValue:@(UIDeviceOrientationPortrait) forKey:@"orientation"];
        [[NSNotificationCenter defaultCenter] postNotificationName:UIDeviceOrientationDidChangeNotification object:[UIDevice currentDevice]];
        
        if (@available(iOS 16.0, *)) {
            UIWindowScene *scene = (UIWindowScene *)strongSelf.window.windowScene;
            if (!scene) {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                        scene = (UIWindowScene *)s; break;
                    }
                }
            }
            if (scene) {
                UIWindowSceneGeometryPreferencesIOS *geom = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait];
                [scene requestGeometryUpdateWithPreferences:geom errorHandler:nil];
            }
        } else {
            [UIViewController attemptRotationToDeviceOrientation];
        }
    });
}

#pragma mark - Debug Information Dumper

#if ENABLE_DEBUG_LOGGING
+ (NSString *)dumpViewHierarchy:(UIView *)view depth:(int)depth maxDepth:(int)maxDepth {
    if (!view || depth > maxDepth) return @"";
    NSMutableString *result = [NSMutableString string];
    NSString *indent = [@"" stringByPaddingToLength:depth*2 withString:@"-" startingAtIndex:0];
    
    CGRect f = view.frame;
    [result appendFormat:@"%@ %@ (F:{%.1f,%.1f,%.1f,%.1f}, Alpha:%.2f, Hidden:%d)\n", indent, NSStringFromClass([view class]), f.origin.x, f.origin.y, f.size.width, f.size.height, view.alpha, view.isHidden];
    
    for (UIView *sub in view.subviews) {
        [result appendString:[self dumpViewHierarchy:sub depth:depth + 1 maxDepth:maxDepth]];
    }
    return result;
}

+ (void)captureDebugInfoToClipboard:(UIViewController *)topVC window:(UIWindow *)window isLandscape:(BOOL)isLandscape {
    NSMutableString *log = [NSMutableString stringWithString:@"\n=== LPV DEBUG LOG ===\n"];
    [log appendFormat:@"Time: %@\n", [NSDate date]];
    [log appendFormat:@"BundleID: %@\n", [[NSBundle mainBundle] bundleIdentifier]];
    [log appendFormat:@"Orientation: %@\n", isLandscape ? @"Landscape" : @"Portrait"];
    
    [log appendFormat:@"\n[Controllers]\n"];
    [log appendFormat:@"TopVC: %@\n", topVC ? NSStringFromClass([topVC class]) : @"nil"];
    if (topVC.parentViewController) {
        [log appendFormat:@"ParentVC: %@\n", NSStringFromClass([topVC.parentViewController class])];
    }
    
    UINavigationController *nav = [self findValidNavigationControllerFor:topVC];
    [log appendFormat:@"ValidNavVC: %@\n", nav ? NSStringFromClass([nav class]) : @"nil"];
    
    [log appendFormat:@"\n[TopVC View Hierarchy (Depth 12)]\n"];
    if (topVC && topVC.view) {
        [log appendString:[self dumpViewHierarchy:topVC.view depth:0 maxDepth:12]];
    }
    
    [log appendFormat:@"\n[Window View Hierarchy (Depth 12)]\n"];
    if (window) {
        [log appendString:[self dumpViewHierarchy:window depth:0 maxDepth:12]];
    }
    
    [log appendString:@"=====================\n"];
    
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = log;
    
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [feedback prepare];
    [feedback impactOccurred];
}
#endif

#pragma mark - Gesture & Haptic Handling

- (void)handlePan:(LPVReversePanGesture *)pan {
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    UINavigationController *nav = [LeftPanWindowHelper findValidNavigationControllerFor:topVC];
    
    UIWindow *window = pan.view.window ?: self.window;
    BOOL isLandscape = NO;
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (@available(iOS 13.0, *)) {
        isLandscape = UIInterfaceOrientationIsLandscape(window.windowScene.interfaceOrientation);
    } else {
        isLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    }
#pragma clang diagnostic pop
    
    if (pan.state == UIGestureRecognizerStateBegan) {
        
#if ENABLE_DEBUG_LOGGING
        [LeftPanWindowHelper captureDebugInfoToClipboard:topVC window:window isLandscape:isLandscape];
#endif
        
        self.systemTarget = nil;
        self.systemAction = NULL;
        self.useFallbackMode = YES;

        if (nav && !isLandscape) {
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
            BOOL isWeChatMiniProgram = [bundleID isEqualToString:@"com.tencent.xin"] && [NSStringFromClass([topVC class]) containsString:@"WAWebView"];
            
            // Extreme Safety Net: WeChat Mini Programs MUST be forced into Fallback Mode.
            // Bypassing their JS engines with system interactive transitions causes fatal white screens!
            if (isSpecialApp_Huya() || isTiebaPBViewController(topVC) || isWeChatMiniProgram) {
                self.useFallbackMode = YES;
            } else {
                @try {
                    if (nav.interactivePopGestureRecognizer && !nav.interactivePopGestureRecognizer.isEnabled) {
                        self.useFallbackMode = YES;
                    } else {
                        NSArray *targets = [nav.interactivePopGestureRecognizer valueForKey:@"targets"];
                        if (targets && targets.count > 0) {
                            id internalTarget = [targets.firstObject valueForKey:@"target"];
                            SEL internalAction = NSSelectorFromString(@"handleNavigationTransition:");
                            if (internalTarget && [internalTarget respondsToSelector:internalAction]) {
                                self.systemTarget = internalTarget;
                                self.systemAction = internalAction;
                                self.useFallbackMode = NO; 
                            }
                        }
                    }
                } @catch (NSException *e) { }
            }
        }
    }

    if (!self.useFallbackMode && self.systemTarget) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.systemTarget performSelector:self.systemAction withObject:pan];
        #pragma clang diagnostic pop
        
        if (pan.state == UIGestureRecognizerStateBegan) {
            dispatch_async(dispatch_get_main_queue(), ^{
                id<UIViewControllerTransitionCoordinator> coordinator = topVC.transitionCoordinator ?: nav.transitionCoordinator;
                if (coordinator && [coordinator initiallyInteractive]) {
                    if (@available(iOS 10.0, *)) {
                        [coordinator notifyWhenInteractionChangesUsingBlock:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                            if (![context isCancelled]) {
#ifndef DISABLE_VIBRATION
                                #if !ENABLE_DEBUG_LOGGING
                                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                                [feedback prepare];
                                [feedback impactOccurred];
                                #endif
#endif
                            }
                        }];
                    }
                }
            });
        }
    } else {
        [self handleFallbackPan:pan isLandscape:isLandscape topVC:topVC nav:nav];
    }
}

- (void)handleFallbackPan:(LPVReversePanGesture *)pan isLandscape:(BOOL)isLandscape topVC:(UIViewController *)topVC nav:(UINavigationController *)nav {
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGPoint trans = [pan translationInView:pan.view];
        CGPoint vel = [pan velocityInView:pan.view];
        CGFloat screenWidth = pan.view.bounds.size.width;
        
        BOOL success = NO;
        if (vel.x > kLPVFallbackSuccessVelocity) {
            success = (trans.x > kLPVFallbackMinFlickTranslation);
        } else if (vel.x < -kLPVFallbackSuccessVelocity) {
            success = NO;
        } else {
            CGFloat ratio = isSpecialApp_Huya() ? kLPVHuyaPortraitSuccessTranslationRatio : kLPVPortraitSuccessTranslationRatio;
            CGFloat requiredTrans = isLandscape ? kLPVFallbackSuccessTranslation : (screenWidth * ratio);
            success = (trans.x > requiredTrans);
        }
        
        if (success) {
            BOOL supportsPortrait = isLandscape ? [LeftPanWindowHelper isPortraitSupportedForWindow:self.window topVC:topVC] : YES;
            
            dispatch_async(dispatch_get_main_queue(), ^{
#ifndef DISABLE_VIBRATION
                #if !ENABLE_DEBUG_LOGGING
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback prepare];
                [feedback impactOccurred];
                #endif
#endif
                if (isLandscape && supportsPortrait) {
                    [self forcePortraitOrientation];
                } else {
                    
                    // UI-BOT TAKEOVER FOR WECHAT MINI PROGRAMS
                    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
                    if ([bundleID isEqualToString:@"com.tencent.xin"] && [NSStringFromClass([topVC class]) containsString:@"WAWebView"]) {
                        BOOL executed = NO;
                        if (nav && nav.viewControllers.count > 1) {
                            // Sub-page: Target the Navigation Back Button (<)
                            executed = [LeftPanWindowHelper clickWeChatBackButton:self.window];
                        } else {
                            // Root-page: Target the Capsule Close Button (O)
                            executed = [LeftPanWindowHelper clickWeChatCapsuleCloseButton:self.window];
                        }
                        
                        // CRITICAL: If the bot fails to find the button, DO NOT fallback to popViewController!
                        // Forcing a pop on the JS Engine guarantees a white-screen deadlock. 
                        // It is infinitely safer to silently fail and let the user tap the physical button.
                        if (executed) return;
                        return; // Silent abort
                    }
                    
                    [LeftPanWindowHelper closeTopViewControllerHierarchy:topVC];
                }
            });
        }
    }
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.pan) return YES;

#if ENABLE_DEBUG_LOGGING
    // -------------------------------------------------------------
    // ULTIMATE GOD MODE (DEBUG ONLY)
    // Instantly intercepts and authorizes the gesture regardless of zone, 
    // velocity, game engines, or view hierarchies. Guaranteed to dump logs!
    // -------------------------------------------------------------
    return YES;
#endif

    UIWindow *window = self.pan.view.window ?: self.window;
    BOOL isLandscape = NO;
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (@available(iOS 13.0, *)) {
        isLandscape = UIInterfaceOrientationIsLandscape(window.windowScene.interfaceOrientation);
    } else {
        isLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    }
#pragma clang diagnostic pop

    CGPoint loc = [self.pan locationInView:self.pan.view];
    CGFloat screenWidth = self.pan.view.bounds.size.width;

    if (isLandscape) {
        if (loc.x < screenWidth - kLPVLandscapeZoneWidth) {
            return NO;
        }
    } else {
        CGFloat ratio = isSpecialApp_Huya() ? kLPVHuyaPortraitZoneRatio : kLPVPortraitZoneRatio;
        if (loc.x < screenWidth * ratio) {
            return NO;
        }
    }

    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];

    if ([LeftPanWindowHelper isForbiddenAppViewController:topVC]) {
        return NO;
    }

    if (!isSpecialApp_Huya()) {
        if ([LeftPanWindowHelper hasGameEngineView:window depth:0] || 
            [LeftPanWindowHelper hasGameEngineView:topVC.view depth:0]) {
            return NO;
        }
    }

    CGPoint rawVel = [self.pan rawVelocityInView:self.pan.view];
    if (rawVel.x >= kLPVGestureStartVelocityThreshold) { 
        return NO;
    }
    if (fabs(rawVel.x) <= fabs(rawVel.y) * 1.3) { 
        return NO;
    }

    if (![LeftPanWindowHelper canGoBack:topVC isLandscape:isLandscape]) {
        return NO;
    }

    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer == self.pan) {
        if ([otherGestureRecognizer isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
            return NO;
        }
        
#if ENABLE_DEBUG_LOGGING
        return YES;
#endif
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
#if ENABLE_DEBUG_LOGGING
    return YES;
#endif
    return NO;
}

@end

#pragma mark - Global Window Injection

static void attachHelperToWindow(UIWindow *window) {
    if (!window || ![window isKindOfClass:[UIWindow class]]) return;
    if (!objc_getAssociatedObject(window, &kWindowHelperKey)) {
        LeftPanWindowHelper *helper = [[LeftPanWindowHelper alloc] initWithWindow:window];
        objc_setAssociatedObject(window, &kWindowHelperKey, helper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void (*orig_UIWindow_makeKeyAndVisible)(id, SEL);
static void swiz_UIWindow_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_UIWindow_makeKeyAndVisible(self, _cmd);
    attachHelperToWindow(self);
}

__attribute__((constructor)) static void init_leftPanGlobal(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[UIWindow class]]) {
            attachHelperToWindow((UIWindow *)note.object);
        }
    }];

    Class winClass = [UIWindow class];
    Method m = class_getInstanceMethod(winClass, @selector(makeKeyAndVisible));
    if (m) {
        orig_UIWindow_makeKeyAndVisible = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swiz_UIWindow_makeKeyAndVisible);
    }
}
