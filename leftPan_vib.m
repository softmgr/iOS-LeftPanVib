#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------
// CONFIGURATION
// ---------------------------------------------------------
// Define the starting trigger zone ratio.
// (2.0 / 3.0) means the gesture will only be recognized in the 
// rightmost 1/3 of the screen. The left 2/3 will be ignored.
#define kLPVActiveZoneRatio (2.0 / 3.0)

static char kWindowHelperKey;

#pragma mark - Custom Gesture Recognizer (Coordinate Inversion)

// We subclass UIPanGestureRecognizer to invert the X-axis translation.
// This tricks the iOS native interactive transition engine into treating a Right-To-Left 
// swipe as a standard Left-To-Right pop gesture, granting us the 100% native slide animation.
@interface LPVReversePanGesture : UIPanGestureRecognizer
- (CGPoint)rawVelocityInView:(UIView *)view;
@end

@implementation LPVReversePanGesture
- (CGPoint)rawVelocityInView:(UIView *)view {
    return [super velocityInView:view];
}

// Invert X translation: sliding left (negative X) becomes positive X.
- (CGPoint)translationInView:(UIView *)view {
    CGPoint t = [super translationInView:view];
    return CGPointMake(-t.x, t.y);
}

// Invert X velocity.
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
        // Crucial: Intercept and cancel lower-level app gestures (e.g., Bilibili's scroll views)
        _pan.cancelsTouchesInView = YES;
        _pan.delaysTouchesBegan = NO;
        [window addGestureRecognizer:_pan];
    }
    return self;
}

#pragma mark - Controller Lookup

// Recursively find the top-most visible view controller
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

// Find the closest active UINavigationController in the chain
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

// Determine if the current page can be popped or dismissed
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

#pragma mark - Gesture & Haptic Handling

- (void)handlePan:(LPVReversePanGesture *)pan {
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    
    if (pan.state == UIGestureRecognizerStateBegan) {
        UINavigationController *nav = [LeftPanWindowHelper findNavControllerFor:topVC];
        self.systemTarget = nil;
        self.systemAction = NULL;
        self.useFallbackMode = YES;

        // Try to hijack the system's native interactive pop transition engine
        if (nav) {
            @try {
                NSArray *targets = [nav.interactivePopGestureRecognizer valueForKey:@"targets"];
                if (targets && targets.count > 0) {
                    id internalTarget = [targets.firstObject valueForKey:@"target"];
                    SEL internalAction = NSSelectorFromString(@"handleNavigationTransition:");
                    if (internalTarget && [internalTarget respondsToSelector:internalAction]) {
                        self.systemTarget = internalTarget;
                        self.systemAction = internalAction;
                        self.useFallbackMode = NO; // Hijack successful
                    }
                }
            } @catch (NSException *e) {
                // Ignore KVC exceptions and safely fallback
            }
        }
    }

    // Forward the inverted pan gesture to the native iOS transition engine.
    if (!self.useFallbackMode && self.systemTarget) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.systemTarget performSelector:self.systemAction withObject:pan];
        #pragma clang diagnostic pop
        
        // When the user lifts their finger, the native transition decides whether to pop or snap back.
        // We observe the transition coordinator to vibrate ONLY if the pop actually succeeds.
        if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
            id<UIViewControllerTransitionCoordinator> coordinator = topVC.transitionCoordinator;
            if (coordinator && [coordinator initiallyInteractive]) {
                [coordinator notifyWhenInteractionChangesUsingBlock:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                    // isCancelled == NO means the user swiped far enough to complete the pop
                    if (![context isCancelled]) {
                        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                        [feedback prepare];
                        [feedback impactOccurred];
                    }
                }];
            }
        }
    } else {
        [self handleFallbackPan:pan topVC:topVC];
    }
}

// Fallback logic for presented ViewControllers without a NavigationController
- (void)handleFallbackPan:(LPVReversePanGesture *)pan topVC:(UIViewController *)topVC {
    if (pan.state == UIGestureRecognizerStateEnded) {
        // Since pan is inverted, a left swipe results in a POSITIVE X translation
        CGPoint trans = [pan translationInView:pan.view];
        CGPoint vel = [pan velocityInView:pan.view];
        
        // Only dismiss and vibrate if the user swiped far enough (> 80pt) or fast enough.
        // If they scrubbed back (trans.x < 80), nothing happens (simulating a snap back).
        if (trans.x > 80.0 || vel.x > 400.0) {
            if (topVC && topVC.presentingViewController) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                    [feedback prepare];
                    [feedback impactOccurred];
                    [topVC dismissViewControllerAnimated:YES completion:nil];
                });
            }
        }
    }
}

#pragma mark - UIGestureRecognizerDelegate (Priority & Conflict Resolution)

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.pan) return YES;

    CGPoint loc = [self.pan locationInView:self.pan.view];
    CGFloat screenWidth = self.pan.view.bounds.size.width;

    // 1. Touch origin limit: Must be in the rightmost 1/3 of the screen.
    if (loc.x < screenWidth * kLPVActiveZoneRatio) {
        return NO;
    }

    // 2. Intent must be a Left Swipe.
    // We use rawVelocity (before inversion) to accurately determine physical finger direction.
    CGPoint rawVel = [self.pan rawVelocityInView:self.pan.view];
    if (rawVel.x >= -40) { // Must be moving left (negative X)
        return NO;
    }
    if (fabs(rawVel.x) <= fabs(rawVel.y) * 1.3) { // Must be primarily horizontal
        return NO;
    }

    // 3. Prevent triggering if the user is already on the root page
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    if (![LeftPanWindowHelper canGoBack:topVC]) {
        return NO;
    }

    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer == self.pan) {
        // Do not block the system's native left-edge pan gesture
        if ([otherGestureRecognizer isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
            return NO;
        }
        // Core Logic: Force all app-specific scroll views (like Bilibili comments) to wait and yield
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // Strictly prevent simultaneous gesture recognition to ensure clean interception
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
    // Listen for KeyWindow changes to attach our gesture globally
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[UIWindow class]]) {
            attachHelperToWindow((UIWindow *)note.object);
        }
    }];

    // Swizzle makeKeyAndVisible for early injection
    Class winClass = [UIWindow class];
    Method m = class_getInstanceMethod(winClass, @selector(makeKeyAndVisible));
    if (m) {
        orig_UIWindow_makeKeyAndVisible = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swiz_UIWindow_makeKeyAndVisible);
    }
}
