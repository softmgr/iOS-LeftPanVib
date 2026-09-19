#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------
// CONFIGURATION (Constants for easy maintenance)
// ---------------------------------------------------------

// 1. Trigger Zones (Where the gesture starts)
#define kLPVPortraitZoneRatio (2.0 / 3.0)
#define kLPVLandscapeZoneWidth 45.0

// 2. Intent Thresholds (How fast/horizontal the finger must move to begin)
#define kLPVGestureStartVelocityThreshold -40.0

// 3. Success Thresholds (How far/fast to swipe to actually trigger the 'Back' action)
#define kLPVPortraitSuccessTranslationRatio (1.0 / 3.0)
#define kLPVPortraitSuccessVelocity 300.0
#define kLPVLandscapeSuccessTranslation 80.0
#define kLPVLandscapeSuccessVelocity 300.0


static char kWindowHelperKey;

#pragma mark - Custom Gesture Recognizer (Coordinate Inversion & System Cheating)

@interface LPVReversePanGesture : UIPanGestureRecognizer
@property (nonatomic, assign) BOOL forcePop;
@property (nonatomic, assign) BOOL forceCancel;
- (CGPoint)rawVelocityInView:(UIView *)view;
- (CGPoint)rawTranslationInView:(UIView *)view;
@end

@implementation LPVReversePanGesture
- (CGPoint)rawVelocityInView:(UIView *)view {
    return [super velocityInView:view];
}
- (CGPoint)rawTranslationInView:(UIView *)view {
    return [super translationInView:view];
}

// Invert X translation. If forced, cheat the system engine to guarantee outcome.
- (CGPoint)translationInView:(UIView *)view {
    if (self.forcePop) return CGPointMake(view ? view.bounds.size.width : 1000.0, 0);
    if (self.forceCancel) return CGPointZero;
    
    CGPoint t = [super translationInView:view];
    return CGPointMake(-t.x, t.y);
}

// Invert X velocity. If forced, cheat the system engine to guarantee outcome.
- (CGPoint)velocityInView:(UIView *)view {
    if (self.forcePop) return CGPointMake(2000.0, 0);
    if (self.forceCancel) return CGPointZero;
    
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
        _pan.delaysTouchesBegan = NO;
        [window addGestureRecognizer:_pan];
    }
    return self;
}

#pragma mark - Controller & Game Engine Lookup

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

+ (BOOL)canGoBack:(UIViewController *)topVC {
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

+ (BOOL)isGameViewController:(UIViewController *)vc {
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

#pragma mark - Device Orientation Control (Ultimate Penetration)

- (void)legacyForcePortrait {
    SEL selector = NSSelectorFromString(@"setOrientation:");
    if ([[UIDevice currentDevice] respondsToSelector:selector]) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[UIDevice instanceMethodSignatureForSelector:selector]];
        [invocation setSelector:selector];
        [invocation setTarget:[UIDevice currentDevice]];
        int val = UIInterfaceOrientationPortrait;
        [invocation setArgument:&val atIndex:2];
        [invocation invoke];
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

- (void)forcePortraitOrientation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 16.0, *)) {
            UIWindowScene *scene = (UIWindowScene *)self.window.windowScene;
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
                [scene requestGeometryUpdateWithPreferences:geom errorHandler:^(NSError *error) {
                    [self legacyForcePortrait];
                }];
                return;
            }
        }
        [self legacyForcePortrait];
    });
}

#pragma mark - Gesture & Haptic Handling

- (void)handlePan:(LPVReversePanGesture *)pan {
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    UINavigationController *nav = [LeftPanWindowHelper findNavControllerFor:topVC];
    
    UIWindow *window = pan.view.window ?: self.window;
    BOOL isLandscape = NO;
    if (@available(iOS 13.0, *)) {
        isLandscape = UIInterfaceOrientationIsLandscape(window.windowScene.interfaceOrientation);
    } else {
        isLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    }
    
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.systemTarget = nil;
        self.systemAction = NULL;
        self.useFallbackMode = YES;

        if (nav && !isLandscape) {
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

    BOOL isEnded = (pan.state == UIGestureRecognizerStateEnded);
    BOOL isCancelled = (pan.state == UIGestureRecognizerStateCancelled);
    BOOL shouldPop = NO;
    
    // Core Logic: Decide the fate of this gesture BEFORE passing it to the system engine
    if (isEnded) {
        CGPoint rawTrans = [pan rawTranslationInView:pan.view];
        CGPoint rawVel = [pan rawVelocityInView:pan.view];
        CGFloat transX = -rawTrans.x; // Realize physical left swipe as positive value
        CGFloat velX = -rawVel.x;
        CGFloat screenWidth = pan.view.bounds.size.width;
        
        if (isLandscape) {
            shouldPop = (transX > kLPVLandscapeSuccessTranslation || velX > kLPVLandscapeSuccessVelocity);
        } else {
            shouldPop = (transX > (screenWidth * kLPVPortraitSuccessTranslationRatio) || velX > kLPVPortraitSuccessVelocity);
        }
    }
    
    // Setup system engine constraints and haptics
    if (isEnded || isCancelled) {
        // If we decided it should pop, we force the system engine to see 100% progress.
        // If we decided it shouldn't, we force the system engine to see 0% progress.
        pan.forcePop = shouldPop;
        pan.forceCancel = !shouldPop;
        
        if (shouldPop) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback prepare];
                [feedback impactOccurred];
            });
        }
    } else {
        pan.forcePop = NO;
        pan.forceCancel = NO;
    }

    // Execute Actions
    if (!self.useFallbackMode && self.systemTarget) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        // System engine will now read our 'forced' values and 100% obey our decision
        [self.systemTarget performSelector:self.systemAction withObject:pan];
        #pragma clang diagnostic pop
    } else {
        if (isEnded && shouldPop) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (isLandscape) {
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
    if (@available(iOS 13.0, *)) {
        isLandscape = UIInterfaceOrientationIsLandscape(window.windowScene.interfaceOrientation);
    } else {
        isLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    }

    CGPoint loc = [self.pan locationInView:self.pan.view];
    CGFloat screenWidth = self.pan.view.bounds.size.width;
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];

    if (isLandscape) {
        if ([LeftPanWindowHelper isGameViewController:topVC]) {
            return NO;
        }
        if (loc.x < screenWidth - kLPVLandscapeZoneWidth) {
            return NO;
        }
    } else {
        if (loc.x < screenWidth * kLPVPortraitZoneRatio) {
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

    if (![LeftPanWindowHelper canGoBack:topVC]) {
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
