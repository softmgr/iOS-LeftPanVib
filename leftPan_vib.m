#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// =========================================================
// DEBUG SWITCH: Set to 1 to enable Full Hierarchy Logging, 0 for Release
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

static BOOL isSpecialApp_Amap(void) {
    static BOOL isAmap = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        isAmap = [bundleID isEqualToString:@"com.autonavi.amap"];
    });
    return isAmap;
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

#pragma mark - Universal Hierarchy Armor-Piercing Algorithm

+ (UIWindow *)resolveKeyWindow {
    UIWindow *foundWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) {
                        foundWindow = w;
                        break;
                    }
                }
            }
            if (foundWindow) break;
        }
    }
    if (!foundWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        foundWindow = [[UIApplication sharedApplication] keyWindow];
#pragma clang diagnostic pop
    }
    return foundWindow;
}

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

+ (BOOL)isAmapHomePage:(UIView *)rootView {
    if (!rootView) return NO;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:rootView];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (v.hidden || v.alpha < 0.05) continue;
        
        NSString *cls = NSStringFromClass([v class]);
        if ([cls isEqualToString:@"WINTabBar"] || 
            [cls isEqualToString:@"WINQuickSearchBarV2"] ||
            [cls isEqualToString:@"AMapUIWaterFallContentSlidableView"]) {
            return YES;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return NO;
}

+ (BOOL)canGoBack:(UIViewController *)topVC window:(UIWindow *)window isLandscape:(BOOL)isLandscape {
    if (isLandscape) return YES;
    if (!topVC) return NO;
    
    if (isTiebaPBViewController(topVC)) return YES;
    
    if (isSpecialApp_Amap()) {
        UIWindow *win = window ?: topVC.view.window ?: [self resolveKeyWindow];
        if ([self isAmapHomePage:win ?: topVC.view]) {
            return NO; // Suppress gesture on root map to avoid exiting app
        }
        return YES; // Enable custom LPV back in Subpages and Navigation
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

#pragma mark - Amap Precision Return Engine

+ (CGFloat)getSafeAreaTop:(UIWindow *)window {
    if (@available(iOS 11.0, *)) {
        if (window && window.safeAreaInsets.top > 0) {
            return window.safeAreaInsets.top;
        }
    }
    return 20.0;
}

+ (CGFloat)getSafeAreaBottom:(UIWindow *)window {
    if (@available(iOS 11.0, *)) {
        if (window && window.safeAreaInsets.bottom > 0) {
            return window.safeAreaInsets.bottom;
        }
    }
    return 0.0;
}

+ (void)dispatchTouchToWindow:(UIWindow *)window atPoint:(CGPoint)pt {
    UIView *hit = [window hitTest:pt withEvent:nil];
    if (hit) {
        [hit touchesBegan:[NSSet set] withEvent:nil];
        [hit touchesEnded:[NSSet set] withEvent:nil];
    }
}

+ (void)closeAmapPage:(UIViewController *)topVC window:(UIWindow *)window {
    UIWindow *targetWin = window ?: topVC.view.window ?: [self resolveKeyWindow];
    if (!targetWin) return;

    CGFloat screenW = targetWin.bounds.size.width;
    CGFloat screenH = targetWin.bounds.size.height;
    CGFloat safeTop = [self getSafeAreaTop:targetWin];
    CGFloat safeBottom = [self getSafeAreaBottom:targetWin];

    CGPoint ptTopLeft = CGPointMake(25.0, safeTop + 22.0);
    CGPoint ptBottomLeft = CGPointMake(50.0, screenH - safeBottom - 48.0);

    // =========================================================================
    // Core Logic 1: Center Physical Hit-Test (Immune to recycled off-screen views)
    // =========================================================================
    CGPoint centerPt = CGPointMake(screenW * 0.5, screenH * 0.5);
    UIView *centerHit = [targetWin hitTest:centerPt withEvent:nil];
    
    BOOL isNavigating = YES; // Assume Navigation (Map) by default
    UIView *curr = centerHit;
    while (curr) {
        NSString *cls = NSStringFromClass([curr class]);
        // If the physical center of the screen is covered by a list, it's a Subpage/Settings.
        if ([cls containsString:@"ScrollView"] || 
            [cls containsString:@"ListView"] || 
            [cls containsString:@"TableView"] || 
            [cls containsString:@"SheetsView"]) {
            isNavigating = NO;
            break;
        }
        curr = curr.superview;
    }

    // =========================================================================
    // Core Logic 2: Top-Left Actionability Validation (Avoid fake buttons)
    // =========================================================================
    UIView *hitTopLeft = [targetWin hitTest:ptTopLeft withEvent:nil];
    BOOL topLeftHasAction = NO;
    curr = hitTopLeft;
    for (int i = 0; i < 5 && curr; i++) {
        // Validate UIControl targets
        if ([curr isKindOfClass:[UIControl class]] && ((UIControl *)curr).allTargets.count > 0) {
            topLeftHasAction = YES; 
            break;
        }
        // Validate Tap Gesture Recognizers (AJX native routing method)
        for (UIGestureRecognizer *gr in curr.gestureRecognizers) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]] || [NSStringFromClass([gr class]) containsString:@"Tap"]) {
                topLeftHasAction = YES; 
                break;
            }
        }
        if (topLeftHasAction) break;
        curr = curr.superview;
    }

    // Decision Making:
    // If the top-left item is just an inactive turn-icon (has no actionable targets), 
    // it's a dead end. We MUST be in Navigation mode, so we force Bottom-Left Exit.
    if (!topLeftHasAction) {
        isNavigating = YES;
    }

    // Execute precision Touch UI-Bot injection
    if (isNavigating) {
        [self dispatchTouchToWindow:targetWin atPoint:ptBottomLeft];
    } else {
        [self dispatchTouchToWindow:targetWin atPoint:ptTopLeft];
    }
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

// Targeted Interception: Isolate WeChat Mini Programs/Skyline to prevent white-screen crashes
+ (BOOL)isForbiddenAppViewController:(UIViewController *)vc {
    if (!vc) return NO;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        UIViewController *curr = vc;
        while (curr) {
            NSString *cls = NSStringFromClass([curr class]);
            if ([cls containsString:@"WAWebView"] || 
                [cls containsString:@"WAGame"] || 
                [cls containsString:@"Skyline"] || 
                [cls containsString:@"WAUI"]) {
                return YES;
            }
            curr = curr.parentViewController;
        }
    }
    return NO;
}

// Deeply scan view hierarchy to block third-party game rendering engines
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
            if (isSpecialApp_Huya() || isTiebaPBViewController(topVC) || isSpecialApp_Amap()) {
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
        [self handleFallbackPan:pan isLandscape:isLandscape topVC:topVC];
    }
}

- (void)handleFallbackPan:(LPVReversePanGesture *)pan isLandscape:(BOOL)isLandscape topVC:(UIViewController *)topVC {
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
                    if (isSpecialApp_Amap()) {
                        [LeftPanWindowHelper closeAmapPage:topVC window:self.window];
                        return;
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

    if (!isSpecialApp_Huya() && !isSpecialApp_Amap()) {
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

    if (![LeftPanWindowHelper canGoBack:topVC window:window isLandscape:isLandscape]) {
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
