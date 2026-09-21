#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------
// CONFIGURATION (Constants for easy maintenance)
// ---------------------------------------------------------

// 1. Trigger Zones
// Default: Active in rightmost 1/5 (20%)
#define kLPVPortraitZoneRatio (4.0 / 5.0)        
// Huya specific: Active in rightmost 1/5
#define kLPVHuyaPortraitZoneRatio (4.0 / 5.0)    
// Active in extreme right edge for landscape
#define kLPVLandscapeZoneWidth 50.0              

// 2. Intent Thresholds
#define kLPVGestureStartVelocityThreshold -40.0

// 3. Fallback Success Thresholds (Used for Custom Transition Apps & Landscape)
// Default: 35% screen width for slow drags
#define kLPVPortraitSuccessTranslationRatio 0.35     
// Huya specific: 20% screen width for short drags
#define kLPVHuyaPortraitSuccessTranslationRatio 0.20 
// Absolute points for landscape slow drags
#define kLPVFallbackSuccessTranslation 100.0         
// Flick velocity threshold
#define kLPVFallbackSuccessVelocity 300.0            
// Anti-jitter minimum distance
#define kLPVFallbackMinFlickTranslation 20.0         


static char kWindowHelperKey;

#pragma mark - Special App Whitelist

// Whitelist mechanism for highly customized apps
static BOOL isSpecialApp_Huya(void) {
    static BOOL isHuya = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        isHuya = [bundleID isEqualToString:@"com.yy.kiwi"];
    });
    return isHuya;
}

#pragma mark - Custom Gesture Recognizer (Coordinate Inversion)

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
        // Delay touches to prevent scroll views or interactive elements from stealing the swipe
        _pan.delaysTouchesBegan = YES;
        [window addGestureRecognizer:_pan];
    }
    return self;
}

#pragma mark - Controller, Engine & Orientation Lookup

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

+ (UINavigationController *)findNavControllerFor:(UIViewController *)vc {
    if ([vc isKindOfClass:[UINavigationController class]]) return (UINavigationController *)vc;
    if (vc.navigationController) return vc.navigationController;
    UIViewController *p = vc.parentViewController;
    while (p) {
        if ([p isKindOfClass:[UINavigationController class]]) return (UINavigationController *)p;
        if (p.navigationController) return p.navigationController;
        p = p.parentViewController;
    }
    return nil;
}

// Custom UI State Heuristic: Accurately identifies Mini Programs & Games without fragile class name matching
+ (BOOL)isCustomUIContainer:(UIViewController *)vc {
    if (!vc) return NO;
    
    // 1. WeChat Mini Program Check
    if ([NSStringFromClass([vc class]) containsString:@"WAWebView"]) {
        return YES;
    }
    
    // 2. Alipay Navigation State Check
    // Alipay Mini Programs and Games replace the native navigation bar with a custom capsule ("..." & "X").
    // We disable the gesture when the native navigation bar is hidden to avoid transition crashes.
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.alipay.iphoneclient"]) {
        UINavigationController *nav = vc.navigationController;
        if (nav) {
            if (nav.navigationBarHidden || nav.navigationBar.isHidden || nav.navigationBar.alpha < 0.01) {
                return YES;
            }
        }
    }
    return NO;
}

// Core Boundary: Bypass stack check for Landscape mode. Portrait relies on strict checks.
+ (BOOL)canGoBack:(UIViewController *)topVC isLandscape:(BOOL)isLandscape {
    // In landscape mode, edge swipes are universally intended to exit fullscreen content
    if (isLandscape) {
        return YES;
    }

    if (!topVC) return NO;
    UINavigationController *nav = [self findNavControllerFor:topVC];
    if (nav && nav.viewControllers.count > 1) {
        return YES;
    }
    if (topVC.presentingViewController && ![topVC isKindOfClass:[UITabBarController class]]) {
        return YES;
    }
    return NO;
}

// Core Boundary: Strictly prohibit triggering in game engine views to prevent gameplay interference
+ (BOOL)isGameViewController:(UIViewController *)vc {
    // Whitelist override: Huya uses Metal/OpenGL for video rendering, exempt it from the block
    if (isSpecialApp_Huya()) {
        return NO;
    }

    if (!vc || !vc.view) return NO;
    NSString *viewClassStr = NSStringFromClass([vc.view class]);
    if ([viewClassStr containsString:@"Unity"] || 
        [viewClassStr containsString:@"EAGL"] || 
        [viewClassStr containsString:@"MTKView"] ||
        [viewClassStr containsString:@"FMetalView"]) {
        return YES;
    }
    return NO;
}

// Accurately determine if the current app supports portrait orientation
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
        if (ipadOrientations) {
            supportedOrientations = ipadOrientations;
        }
    }
    
    if (supportedOrientations && [supportedOrientations isKindOfClass:[NSArray class]]) {
        BOOL hasPortrait = NO;
        for (NSString *orientation in supportedOrientations) {
            if ([orientation isEqualToString:@"UIInterfaceOrientationPortrait"] ||
                [orientation isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) {
                hasPortrait = YES;
                break;
            }
        }
        if (!hasPortrait) {
            return NO; 
        }
    }
    return YES;
}

#pragma mark - Device Orientation Control (Delayed Override)

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
                        scene = (UIWindowScene *)s;
                        break;
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

#pragma mark - Gesture & Haptic Handling

- (void)handlePan:(LPVReversePanGesture *)pan {
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    UINavigationController *nav = [LeftPanWindowHelper findNavControllerFor:topVC];
    
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
        self.systemTarget = nil;
        self.systemAction = NULL;
        self.useFallbackMode = YES;

        if (nav && !isLandscape) {
            // Force Fallback mode for Huya to prevent transition engine crashes
            if (isSpecialApp_Huya()) {
                self.useFallbackMode = YES;
            } else {
                @try {
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
                                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                                [feedback prepare];
                                [feedback impactOccurred];
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
            // Apply targeted translation ratios for customized apps
            CGFloat ratio = isSpecialApp_Huya() ? kLPVHuyaPortraitSuccessTranslationRatio : kLPVPortraitSuccessTranslationRatio;
            CGFloat requiredTrans = isLandscape ? kLPVFallbackSuccessTranslation : (screenWidth * ratio);
            success = (trans.x > requiredTrans);
        }
        
        if (success) {
            BOOL supportsPortrait = isLandscape ? [LeftPanWindowHelper isPortraitSupportedForWindow:self.window topVC:topVC] : YES;
            
            dispatch_async(dispatch_get_main_queue(), ^{
#ifndef DISABLE_VIBRATION
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback prepare];
                [feedback impactOccurred];
#endif
                
                if (isLandscape && supportsPortrait) {
                    [self forcePortraitOrientation];
                } else {
                    if (nav && nav.viewControllers.count > 1) {
                        [nav popViewControllerAnimated:YES];
                    } else if (topVC && topVC.presentingViewController) {
                        [topVC dismissViewControllerAnimated:YES completion:nil];
                    }
                }
            });
        }
    }
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.pan) return YES;

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

    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];

    // Global Interception 1: Disable gesture entirely inside highly custom containers (Alipay Mini Games)
    if ([LeftPanWindowHelper isCustomUIContainer:topVC]) {
        return NO;
    }

    // Global Interception 2: Disable gesture entirely inside rendering game engines
    // Note: Upgraded to apply indiscriminately to both Portrait and Landscape orientations
    if ([LeftPanWindowHelper isGameViewController:topVC]) {
        return NO;
    }

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

    CGPoint rawVel = [self.pan rawVelocityInView:self.pan.view];
    if (rawVel.x >= kLPVGestureStartVelocityThreshold) { 
        return NO;
    }
    if (fabs(rawVel.x) <= fabs(rawVel.y) * 1.3) { 
        return NO;
    }

    // Pass isLandscape parameter to ensure precision in logical execution
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
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
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
