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

// Identify Baidu Tieba's custom Post Detail (PB) View Controllers
static BOOL isTiebaPBViewController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.baidu.tieba"]) return NO;
    
    NSString *vcClassStr = NSStringFromClass([vc class]);
    NSString *parentClassStr = vc.parentViewController ? NSStringFromClass([vc.parentViewController class]) : @"";
    
    // "PBView" and "FirstFloor" are the core containers for Tieba threads.
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

#pragma mark - Controller & Orientation Lookup

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

+ (BOOL)canGoBack:(UIViewController *)topVC isLandscape:(BOOL)isLandscape {
    if (isLandscape) return YES;
    if (!topVC) return NO;
    
    // Safety Net: Always allow gesture on Tieba Post views so Fallback Mode can capture it.
    if (isTiebaPBViewController(topVC)) return YES;
    
    UINavigationController *nav = [self findNavControllerFor:topVC];
    if (nav && nav.viewControllers.count > 1) return YES;
    if (topVC.presentingViewController && ![topVC isKindOfClass:[UITabBarController class]]) return YES;
    
    // Fallback support for Modally Presented Navigation Controllers
    if (nav && nav.presentingViewController) return YES;
    
    return NO;
}

// Targeted Interception: Isolate specific complex containers
+ (BOOL)isForbiddenAppViewController:(UIViewController *)vc {
    if (!vc) return NO;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSString *vcClassStr = NSStringFromClass([vc class]);
    
    // WeChat Specific Rules
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        if ([vcClassStr containsString:@"WAWebView"] || 
            [vcClassStr containsString:@"WAGame"] || 
            [vcClassStr containsString:@"BaseMsgContent"]) {
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
            // Force Fallback for Huya and Tieba Post details where system interactive transitions fail or are blocked
            if (isSpecialApp_Huya() || isTiebaPBViewController(topVC)) {
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
                    
                    // The Ultimate Brute-Force Pop for Tieba Post Views
                    // Tieba's TBCNavigationController overrides and disables standard pop methods.
                    // We extract the pure, unadulterated native implementation from UIKit to bypass their block.
                    if (isTiebaPBViewController(topVC)) {
                        if (nav && nav.viewControllers.count > 1) {
                            Method nativeMethod = class_getInstanceMethod([UINavigationController class], @selector(popViewControllerAnimated:));
                            if (nativeMethod) {
                                IMP nativeImp = method_getImplementation(nativeMethod);
                                ((UIViewController* (*)(id, SEL, BOOL))nativeImp)(nav, @selector(popViewControllerAnimated:), YES);
                            }
                            return;
                        } else if (nav && nav.presentingViewController) {
                            [nav dismissViewControllerAnimated:YES completion:nil];
                            return;
                        }
                    }
                    
                    // Standard routing for normal Fallback mode execution
                    if (nav && nav.viewControllers.count > 1) {
                        [nav popViewControllerAnimated:YES];
                    } else if (nav && nav.presentingViewController) {
                        [nav dismissViewControllerAnimated:YES completion:nil];
                    } else if (topVC && topVC.presentingViewController) {
                        [topVC dismissViewControllerAnimated:YES completion:nil];
                    } else if (topVC.parentViewController && topVC.parentViewController.presentingViewController) {
                        [topVC.parentViewController dismissViewControllerAnimated:YES completion:nil];
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
