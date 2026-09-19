#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------
// CONFIGURATION
// ---------------------------------------------------------
// Portrait mode: trigger zone is the rightmost 1/3 of the screen.
#define kLPVPortraitZoneRatio (2.0 / 3.0)
// Landscape mode: narrow trigger zone (~one finger width from the right edge).
#define kLPVLandscapeZoneWidth 45.0

static char kWindowHelperKey;

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

// Check if the current view is rendered by a known game engine
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

#pragma mark - Gesture & Predictive Haptic Handling

- (void)handlePan:(LPVReversePanGesture *)pan {
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    UINavigationController *nav = [LeftPanWindowHelper findNavControllerFor:topVC];
    
    // Check orientation
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

        // ONLY hijack native transition in Portrait mode.
        // Hijacking in Landscape causes severe orientation glitching (flashing portrait).
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

    // Forward the gesture to native iOS transition engine (Portrait only)
    if (!self.useFallbackMode && self.systemTarget) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.systemTarget performSelector:self.systemAction withObject:pan];
        #pragma clang diagnostic pop
        
        // Portrait Predictive Haptic
        if (pan.state == UIGestureRecognizerStateEnded) {
            CGPoint trans = [pan translationInView:pan.view];
            CGPoint vel = [pan velocityInView:pan.view];
            CGFloat screenWidth = pan.view.bounds.size.width;
            
            // Portrait threshold: 1/3 of width or fast flick
            if (trans.x > screenWidth / 3.0 || vel.x > 300.0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                    [feedback prepare];
                    [feedback impactOccurred];
                });
            }
        }
    } else {
        // Fallback execution for Landscape or Modal views
        [self handleFallbackPan:pan topVC:topVC nav:nav];
    }
}

// Fallback logic for Landscape mode & Presented ViewControllers
- (void)handleFallbackPan:(LPVReversePanGesture *)pan topVC:(UIViewController *)topVC nav:(UINavigationController *)nav {
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGPoint trans = [pan translationInView:pan.view];
        CGPoint vel = [pan velocityInView:pan.view];
        
        // Landscape threshold: Swiping more than 80 points is considered a success
        if (trans.x > 80.0 || vel.x > 300.0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // 1. Haptic Feedback
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback prepare];
                [feedback impactOccurred];
                
                // 2. Perform Back/Dismiss
                if (nav && nav.viewControllers.count > 1) {
                    [nav popViewControllerAnimated:YES];
                } else if (topVC && topVC.presentingViewController) {
                    [topVC dismissViewControllerAnimated:YES completion:nil];
                }
            });
        }
    }
}

#pragma mark - UIGestureRecognizerDelegate (Priority & Conflict Resolution)

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
        // Game Check: Block if it is a known game engine view
        if ([LeftPanWindowHelper isGameViewController:topVC]) {
            return NO;
        }
        // Landscape Zone: Only the extreme right edge (~45 points, ~one finger width)
        if (loc.x < screenWidth - kLPVLandscapeZoneWidth) {
            return NO;
        }
    } else {
        // Portrait Zone: Rightmost 1/3 of the screen
        if (loc.x < screenWidth * kLPVPortraitZoneRatio) {
            return NO;
        }
    }

    // Intent must be a Left Swipe (negative raw X velocity)
    CGPoint rawVel = [self.pan rawVelocityInView:self.pan.view];
    if (rawVel.x >= -40) { 
        return NO;
    }
    // Must be primarily horizontal
    if (fabs(rawVel.x) <= fabs(rawVel.y) * 1.3) { 
        return NO;
    }

    // Prevent triggering if the user is already on the root page
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
