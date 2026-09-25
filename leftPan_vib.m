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
static volatile BOOL g_forceAllowPortrait = NO;

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

+ (BOOL)isFlutterSubpageActive:(UIViewController *)topVC {
    if (!topVC || ![topVC isKindOfClass:NSClassFromString(@"FlutterViewController")]) return NO;
    UIView *fView = topVC.view;
    if (!fView) return NO;

    NSMutableArray *queue = [NSMutableArray arrayWithObject:fView];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *cls = NSStringFromClass([v class]);
        if ([cls containsString:@"ChildClippingView"] || 
            [cls containsString:@"TouchIntercepting"] || 
            [cls containsString:@"PlatformView"] ||
            [cls containsString:@"Video"]) {
            return YES;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return NO;
}

+ (BOOL)canGoBack:(UIViewController *)topVC window:(UIWindow *)window isLandscape:(BOOL)isLandscape {
    if (!topVC) return NO;

    // Generic Flutter Framework Introspection
    if ([topVC isKindOfClass:NSClassFromString(@"FlutterViewController")]) {
        if (isLandscape) {
            return NO;
        }
        return [self isFlutterSubpageActive:topVC];
    }

    if (isLandscape) return YES;
    
    if (isTiebaPBViewController(topVC)) return YES;
    
    if (isSpecialApp_Amap()) {
        UIWindow *win = window ?: topVC.view.window ?: [self resolveKeyWindow];
        if ([self isAmapHomePage:win ?: topVC.view]) {
            return NO; 
        }
        return YES; 
    }
    
    UIDeviceOrientation devOri = [[UIDevice currentDevice] orientation];
    if (UIDeviceOrientationIsLandscape(devOri)) {
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

#pragma mark - Universal Video Player & Fake Landscape Engine

+ (BOOL)isAnyLandscapeActive:(UIWindow *)window topVC:(UIViewController *)topVC isSystemLandscape:(BOOL)isSystemLandscape {
    if (isSystemLandscape) return YES;
    
    UIDeviceOrientation devOri = [[UIDevice currentDevice] orientation];
    if (UIDeviceOrientationIsLandscape(devOri)) {
        return YES;
    }
    
    if (window && window.bounds.size.width > window.bounds.size.height) {
        return YES;
    }
    
    if (topVC && topVC.isViewLoaded && topVC.view.bounds.size.width > topVC.view.bounds.size.height) {
        return YES;
    }
    
    if (window) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        int count = 0;
        while (queue.count > 0 && count < 80) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            count++;
            if (v.hidden || v.alpha < 0.05) continue;
            
            CGAffineTransform t = v.transform;
            if (fabs(t.a) < 0.1 && fabs(t.d) < 0.1) {
                if ((t.b > 0.5 && t.c < -0.5) || (t.b < -0.5 && t.c > 0.5)) {
                    return YES;
                }
            }
            [queue addObjectsFromArray:v.subviews];
        }
    }
    return NO;
}

static void notifyReactNativeOrientationBridge(UIWindow *window) {
    if (!window) return;
    UIView *rootView = nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:NSClassFromString(@"RCTRootView")]) {
            rootView = v;
            break;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    if (!rootView) return;

    id bridge = nil;
    @try {
        bridge = [rootView valueForKey:@"bridge"];
    } @catch (NSException *e) {}

    if (bridge) {
        @try {
            SEL enqueueSel = NSSelectorFromString(@"enqueueJSCall:method:args:completion:");
            if ([bridge respondsToSelector:enqueueSel]) {
                NSMethodSignature *sig = [bridge methodSignatureForSelector:enqueueSel];
                if (sig && sig.numberOfArguments == 6) {
                    void (^emitEvent)(NSString *, NSString *) = ^(NSString *event, NSString *val) {
                        NSArray *args = @[event, @{@"orientation": val, @"deviceOrientation": val}];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setSelector:enqueueSel];
                        [inv setTarget:bridge];
                        NSString *mod = @"RCTDeviceEventEmitter";
                        NSString *meth = @"emit";
                        [inv setArgument:&mod atIndex:2];
                        [inv setArgument:&meth atIndex:3];
                        [inv setArgument:&args atIndex:4];
                        void *nilBlock = NULL;
                        [inv setArgument:&nilBlock atIndex:5];
                        [inv invoke];
                    };
                    emitEvent(@"orientationDidChange", @"PORTRAIT");
                    emitEvent(@"deviceOrientationDidChange", @"PORTRAIT");
                }
            }
        } @catch (NSException *e) {}

        @try {
            id oriModule = nil;
            if ([bridge respondsToSelector:NSSelectorFromString(@"moduleForName:")]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                oriModule = [bridge performSelector:NSSelectorFromString(@"moduleForName:") withObject:@"OrientationLocker"];
                if (!oriModule) {
                    oriModule = [bridge performSelector:NSSelectorFromString(@"moduleForName:") withObject:@"Orientation"];
                }
                #pragma clang diagnostic pop
            }
            if (oriModule) {
                SEL lockSel = NSSelectorFromString(@"lockToPortrait");
                if ([oriModule respondsToSelector:lockSel]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [oriModule performSelector:lockSel];
                    #pragma clang diagnostic pop
                }
            }
        } @catch (NSException *e) {}
    }
}

+ (UIView *)findActualPlayerBackButton:(UIView *)root window:(UIWindow *)window {
    if (!root || !window) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    UIView *bestCandidate = nil;
    CGFloat minDistance = 9999.0;
    
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (v.hidden || v.alpha < 0.1) continue;
        
        CGRect r = [v convertRect:v.bounds toView:window];
        
        if (r.origin.x >= 15.0 && r.origin.x <= 130.0 &&
            r.origin.y >= 20.0 && r.origin.y <= 160.0 &&
            r.size.width >= 18.0 && r.size.width <= 85.0 &&
            r.size.height >= 18.0 && r.size.height <= 85.0) {
            
            BOOL isLikelyButton = NO;
            if ([v isKindOfClass:[UIControl class]]) isLikelyButton = YES;
            if (v.gestureRecognizers.count > 0) isLikelyButton = YES;
            if (v.subviews.count <= 3) isLikelyButton = YES;
            
            if (isLikelyButton) {
                CGFloat dx = r.origin.x - 55.0;
                CGFloat dy = r.origin.y - 65.0;
                CGFloat dist = dx * dx + dy * dy;
                if (dist < minDistance) {
                    minDistance = dist;
                    bestCandidate = v;
                }
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return bestCandidate;
}

+ (void)simulateTapOnVerifiedView:(UIView *)targetView inWindow:(UIWindow *)window {
    if (!targetView || !window) return;
    CGRect r = [targetView convertRect:targetView.bounds toView:window];
    CGPoint pt = CGPointMake(r.origin.x + r.size.width * 0.5, r.origin.y + r.size.height * 0.5);

    if ([targetView isKindOfClass:[UIControl class]]) {
        [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }

    UIView *curr = targetView;
    while (curr && curr != window) {
        for (UIGestureRecognizer *gr in curr.gestureRecognizers) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
                @try {
                    NSArray *targets = [gr valueForKey:@"targets"];
                    for (id t in targets) {
                        id target = [t valueForKey:@"target"];
                        SEL action = NSSelectorFromString([t valueForKey:@"action"] ?: @"");
                        if (target && action && [target respondsToSelector:action]) {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            [target performSelector:action withObject:gr];
                            #pragma clang diagnostic pop
                            return;
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
        curr = curr.superview;
    }

    UIGestureRecognizer *touchHandler = nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        for (UIGestureRecognizer *gr in v.gestureRecognizers) {
            NSString *cls = NSStringFromClass([gr class]);
            if ([cls containsString:@"TouchHandler"]) {
                touchHandler = gr;
                break;
            }
        }
        if (touchHandler) break;
        [queue addObjectsFromArray:v.subviews];
    }

    if (!touchHandler) return;

    @try {
        UITouch *touch = [[UITouch alloc] init];
        if ([touch respondsToSelector:@selector(setWindow:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [touch performSelector:@selector(setWindow:) withObject:window];
            [touch performSelector:@selector(setView:) withObject:targetView];
            #pragma clang diagnostic pop
        } else {
            [touch setValue:window forKey:@"_window"];
            [touch setValue:targetView forKey:@"_view"];
        }

        if ([touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)]) {
            NSMethodSignature *sig = [touch methodSignatureForSelector:@selector(_setLocationInWindow:resetPrevious:)];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:@selector(_setLocationInWindow:resetPrevious:)];
            [inv setTarget:touch];
            [inv setArgument:&pt atIndex:2];
            BOOL reset = YES;
            [inv setArgument:&reset atIndex:3];
            [inv invoke];
        } else {
            [touch setValue:[NSValue valueWithCGPoint:pt] forKey:@"_locationInWindow"];
        }

        if ([touch respondsToSelector:@selector(setPhase:)]) {
            NSMethodSignature *sig = [touch methodSignatureForSelector:@selector(setPhase:)];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:@selector(setPhase:)];
            [inv setTarget:touch];
            UITouchPhase phase = UITouchPhaseBegan;
            [inv setArgument:&phase atIndex:2];
            [inv invoke];
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
        if ([touchHandler respondsToSelector:@selector(touchesBegan:withEvent:)]) {
            [touchHandler touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
        }
#pragma clang diagnostic pop

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.035 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([touch respondsToSelector:@selector(setPhase:)]) {
                NSMethodSignature *sig = [touch methodSignatureForSelector:@selector(setPhase:)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(setPhase:)];
                [inv setTarget:touch];
                UITouchPhase phase = UITouchPhaseEnded;
                [inv setArgument:&phase atIndex:2];
                [inv invoke];
            }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
            if ([touchHandler respondsToSelector:@selector(touchesEnded:withEvent:)]) {
                [touchHandler touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
            }
#pragma clang diagnostic pop
        });
    } @catch (NSException *e) {}
}

static void lockRNOrientationToPortrait(void) {
    Class oriClass = NSClassFromString(@"Orientation");
    if (!oriClass) {
        oriClass = NSClassFromString(@"OrientationLocker");
    }
    if (oriClass) {
        SEL lockPortSel = NSSelectorFromString(@"lockToPortrait");
        if ([oriClass respondsToSelector:lockPortSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [oriClass performSelector:lockPortSel];
            #pragma clang diagnostic pop
        }
        SEL setOriSel = NSSelectorFromString(@"setOrientation:");
        Method m = class_getClassMethod(oriClass, setOriSel);
        if (m) {
            void (*impl)(id, SEL, UIInterfaceOrientationMask) = (void (*)(id, SEL, UIInterfaceOrientationMask))method_getImplementation(m);
            if (impl) {
                impl(oriClass, setOriSel, UIInterfaceOrientationMaskPortrait);
            }
        }
    }
}

+ (void)correctLandscapeViewHierarchy:(UIView *)root targetWidth:(CGFloat)targetW {
    if (!root || targetW <= 0) return;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    int count = 0;

    while (queue.count > 0 && count < 250) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        count++;

        NSString *cls = NSStringFromClass([v class]);
        
        if ([cls containsString:@"Window"] || [cls containsString:@"Transition"] || 
            [cls containsString:@"Layout"] || [cls containsString:@"Screen"] || 
            [cls containsString:@"Root"] || [cls containsString:@"Scroll"] || 
            [cls containsString:@"Provider"] || [cls containsString:@"Navigation"] ||
            [cls containsString:@"Flutter"]) {
            [queue addObjectsFromArray:v.subviews];
            continue;
        }

        CGRect f = v.frame;
        BOOL isVideoView = [cls containsString:@"Video"] || [cls containsString:@"Player"] || [cls containsString:@"IJK"];
        if (isVideoView && f.size.width > targetW + 5.0) {
            CGFloat newW = targetW;
            CGFloat newH = f.size.height;
            if (newH > targetW * 0.70) {
                newH = targetW * (9.0 / 16.0);
            }
            v.frame = CGRectMake(0, f.origin.y, newW, newH);
            v.bounds = CGRectMake(0, 0, newW, newH);
            [v setNeedsLayout];
            [v layoutIfNeeded];
        }

        if (!isVideoView && f.origin.x + f.size.width > targetW + 2.0 && f.size.width < targetW && f.size.width > 10.0) {
            CGFloat newX = targetW - f.size.width - 12.0;
            if (newX < 0) newX = 0;
            v.frame = CGRectMake(newX, f.origin.y, f.size.width, f.size.height);
        }

        [queue addObjectsFromArray:v.subviews];
    }
}

+ (BOOL)searchAndClickPlayerExitButton:(UIView *)root window:(UIWindow *)window {
    if (!root) return NO;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];

    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if (v.hidden) continue;

        NSString *cls = NSStringFromClass([v class]);
        if ([cls containsString:@"CoverView"] || [cls containsString:@"NavBar"]) {
            continue;
        }

        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)v;
            CGRect absFrame = [btn convertRect:btn.bounds toView:window];

            UIView *p = btn.superview;
            BOOL insidePlayerControl = NO;
            while (p && p != root) {
                NSString *pCls = NSStringFromClass([p class]);
                if ([pCls containsString:@"Player"] || [pCls containsString:@"Control"] || [pCls containsString:@"Widget"]) {
                    insidePlayerControl = YES;
                    break;
                }
                p = p.superview;
            }

            if (insidePlayerControl) {
                if (absFrame.origin.x <= 90.0 && absFrame.origin.y <= 90.0 &&
                    absFrame.size.width >= 20.0 && absFrame.size.height >= 20.0) {
                    btn.enabled = YES;
                    btn.userInteractionEnabled = YES;
                    [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                    [btn touchesBegan:[NSSet set] withEvent:nil];
                    [btn touchesEnded:[NSSet set] withEvent:nil];
                    return YES;
                }
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return NO;
}

+ (BOOL)exitVideoFullScreen:(UIViewController *)topVC window:(UIWindow *)window {
    BOOL didTrigger = NO;

    NSArray *safeExitSels = @[
        @"exitFullScreen", @"exitFullscreen", @"exitFullScreenAnimated:",
        @"shrinkScreen", @"toSmallScreen", @"changeToSmallScreen", @"smallScreen",
        @"toggleFullScreen", @"switchFullScreen"
    ];

    for (id obj in @[topVC ?: [NSNull null], topVC.parentViewController ?: [NSNull null]]) {
        if (obj == [NSNull null]) continue;
        UIViewController *vc = (UIViewController *)obj;

        for (NSString *selName in @[@"setIsFullscreen:", @"setIsFullScreen:", @"setFullScreen:", @"setFullscreen:"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([vc respondsToSelector:sel]) {
                NSMethodSignature *sig = [vc methodSignatureForSelector:sel];
                if (sig && sig.numberOfArguments == 3) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:sel];
                    [inv setTarget:vc];
                    BOOL val = NO;
                    [inv setArgument:&val atIndex:2];
                    [inv invoke];
                    didTrigger = YES;
                    break;
                }
            }
        }
        if (didTrigger) break;

        for (NSString *s in safeExitSels) {
            SEL sel = NSSelectorFromString(s);
            if ([vc respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [vc performSelector:sel];
                #pragma clang diagnostic pop
                didTrigger = YES;
                break;
            }
        }
        if (didTrigger) break;
    }

    if (window) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        int count = 0;
        while (queue.count > 0 && count < 180) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            count++;

            for (NSString *s in @[@"dismissFullscreenPlayer", @"exitFullScreen", @"exitFullscreen", @"shrinkScreen", @"toSmallScreen"]) {
                SEL sel = NSSelectorFromString(s);
                if ([v respondsToSelector:sel]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [v performSelector:sel];
                    #pragma clang diagnostic pop
                    didTrigger = YES;
                    break;
                }
            }
            if (didTrigger) break;

            for (NSString *selName in @[@"setIsFullscreen:", @"setIsFullScreen:", @"setFullscreen:", @"setFullScreen:"]) {
                SEL sel = NSSelectorFromString(selName);
                if ([v respondsToSelector:sel]) {
                    NSMethodSignature *sig = [v methodSignatureForSelector:sel];
                    if (sig && sig.numberOfArguments == 3) {
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setSelector:sel];
                        [inv setTarget:v];
                        BOOL val = NO;
                        [inv setArgument:&val atIndex:2];
                        [inv invoke];
                        didTrigger = YES;
                        break;
                    }
                }
            }
            if (didTrigger) break;

            [queue addObjectsFromArray:v.subviews];
        }
    }

    if (!didTrigger) {
        UIView *searchRoot = topVC.view ?: window;
        if (searchRoot) {
            didTrigger = [self searchAndClickPlayerExitButton:searchRoot window:window];
        }
    }

    return didTrigger;
}

#pragma mark - Amap Dual-Strike Return Engine

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

    CGFloat screenH = targetWin.bounds.size.height;
    CGFloat safeTop = [self getSafeAreaTop:targetWin];
    CGFloat safeBottom = [self getSafeAreaBottom:targetWin];

    CGPoint ptTopLeft = CGPointMake(25.0, safeTop + 22.0);
    CGPoint ptBottomLeft = CGPointMake(50.0, screenH - safeBottom - 48.0);

    [self dispatchTouchToWindow:targetWin atPoint:ptTopLeft];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dispatchTouchToWindow:targetWin atPoint:ptBottomLeft];
    });
}

+ (void)closeTopViewControllerHierarchy:(UIViewController *)topVC {
    if ([topVC isKindOfClass:NSClassFromString(@"FlutterViewController")]) {
        if ([topVC respondsToSelector:NSSelectorFromString(@"popRoute")]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [topVC performSelector:NSSelectorFromString(@"popRoute")];
            #pragma clang diagnostic pop
        }
        UIWindow *win = topVC.view.window ?: [self resolveKeyWindow];
        if (win) {
            CGFloat safeTop = [self getSafeAreaTop:win];
            CGPoint ptTopLeft = CGPointMake(25.0, safeTop + 22.0);
            [self dispatchTouchToWindow:win atPoint:ptTopLeft];
        }
        return;
    }

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

// Anti-Bounce Force Rotation Engine
- (void)forcePortraitOrientation {
    g_forceAllowPortrait = YES;
    lockRNOrientationToPortrait();

    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    if (@available(iOS 16.0, *)) {
        if (topVC) [topVC setNeedsUpdateOfSupportedInterfaceOrientations];
        if (self.window.rootViewController) [self.window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    }

    @try {
        SEL setOriSel = NSSelectorFromString(@"setOrientation:");
        if ([[UIDevice currentDevice] respondsToSelector:setOriSel]) {
            NSMethodSignature *sig = [[UIDevice currentDevice] methodSignatureForSelector:setOriSel];
            if (sig && sig.numberOfArguments == 3) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:setOriSel];
                [inv setTarget:[UIDevice currentDevice]];
                NSInteger ori = UIInterfaceOrientationPortrait;
                [inv setArgument:&ori atIndex:2];
                [inv invoke];
            }
        }
    } @catch (NSException *e) {}

    @try {
        [[UIDevice currentDevice] setValue:@(UIDeviceOrientationUnknown) forKey:@"orientation"];
        [[UIDevice currentDevice] setValue:@(UIDeviceOrientationPortrait) forKey:@"orientation"];
    } @catch (NSException *e) {}

    [[NSNotificationCenter defaultCenter] postNotificationName:UIDeviceOrientationDidChangeNotification object:[UIDevice currentDevice]];

    if (@available(iOS 16.0, *)) {
        UIWindowScene *scene = (UIWindowScene *)self.window.windowScene;
        if (!scene) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (s.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
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

    UIWindow *win = self.window ?: [LeftPanWindowHelper resolveKeyWindow];
    notifyReactNativeOrientationBridge(win);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *currWin = self.window ?: [LeftPanWindowHelper resolveKeyWindow];
        if (currWin) {
            CGFloat screenW = currWin.bounds.size.width;
            CGFloat screenH = currWin.bounds.size.height;
            CGFloat targetW = MIN(screenW, screenH);

            [[NSNotificationCenter defaultCenter] postNotificationName:UIDeviceOrientationDidChangeNotification object:[UIDevice currentDevice]];
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
            #pragma clang diagnostic pop

            notifyReactNativeOrientationBridge(currWin);

            UIView *targetBtn = [LeftPanWindowHelper findActualPlayerBackButton:currWin window:currWin];
            if (targetBtn) {
                [LeftPanWindowHelper simulateTapOnVerifiedView:targetBtn inWindow:currWin];
            }

            [LeftPanWindowHelper correctLandscapeViewHierarchy:currWin targetWidth:targetW];
            [currWin setNeedsLayout];
            [currWin layoutIfNeeded];
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_forceAllowPortrait = NO;
        if (@available(iOS 16.0, *)) {
            if (topVC) [topVC setNeedsUpdateOfSupportedInterfaceOrientations];
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

    @try {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = log;
    } @catch (NSException *e) {}

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
    BOOL isSystemLandscape = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (@available(iOS 13.0, *)) {
        isSystemLandscape = UIInterfaceOrientationIsLandscape(window.windowScene.interfaceOrientation);
    } else {
        isSystemLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    }
#pragma clang diagnostic pop

    BOOL isAnyLandscape = [LeftPanWindowHelper isAnyLandscapeActive:window topVC:topVC isSystemLandscape:isSystemLandscape];

    if (pan.state == UIGestureRecognizerStateBegan) {

#if ENABLE_DEBUG_LOGGING
        [LeftPanWindowHelper captureDebugInfoToClipboard:topVC window:window isLandscape:isAnyLandscape];
#endif

        self.systemTarget = nil;
        self.systemAction = NULL;
        self.useFallbackMode = YES;

        if (nav && !isAnyLandscape) {
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
        [self handleFallbackPan:pan isLandscape:isAnyLandscape topVC:topVC];
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
            BOOL isAnyLandscape = [LeftPanWindowHelper isAnyLandscapeActive:self.window topVC:topVC isSystemLandscape:isLandscape];

            dispatch_async(dispatch_get_main_queue(), ^{
#ifndef DISABLE_VIBRATION
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback prepare];
                [feedback impactOccurred];
#endif
                if (isAnyLandscape) {
                    BOOL videoHandled = [LeftPanWindowHelper exitVideoFullScreen:topVC window:self.window];
                    [self forcePortraitOrientation];

                    if (!videoHandled && !isSpecialApp_Amap()) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            UIWindow *win = self.window ?: [LeftPanWindowHelper resolveKeyWindow];
                            if (win && win.bounds.size.width > win.bounds.size.height) {
                                [LeftPanWindowHelper closeTopViewControllerHierarchy:topVC];
                            }
                        });
                    }
                } else {
                    if (isSpecialApp_Amap()) {
                        [LeftPanWindowHelper closeAmapPage:topVC window:self.window];
                    } else {
                        [LeftPanWindowHelper closeTopViewControllerHierarchy:topVC];
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
    BOOL isSystemLandscape = NO;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (@available(iOS 13.0, *)) {
        isSystemLandscape = UIInterfaceOrientationIsLandscape(window.windowScene.interfaceOrientation);
    } else {
        isSystemLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    }
#pragma clang diagnostic pop

    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    BOOL isLandscape = [LeftPanWindowHelper isAnyLandscapeActive:window topVC:topVC isSystemLandscape:isSystemLandscape];

    // Generic Flutter Framework Introspection: Disable gesture in landscape to protect dual-axis player controls
    if ([topVC isKindOfClass:NSClassFromString(@"FlutterViewController")] && isLandscape) {
        return NO;
    }

    CGPoint loc = [self.pan locationInView:self.pan.view];
    CGFloat screenWidth = self.pan.view.bounds.size.width;

    if (isLandscape) {
        if (loc.x < screenWidth - kLPVLandscapeZoneWidth) return NO;
    } else {
        CGFloat ratio = isSpecialApp_Huya() ? kLPVHuyaPortraitZoneRatio : kLPVPortraitZoneRatio;
        if (loc.x < screenWidth * ratio) return NO;
    }

    if ([LeftPanWindowHelper isForbiddenAppViewController:topVC]) return NO;

    if (!isSpecialApp_Huya() && !isSpecialApp_Amap()) {
        if ([LeftPanWindowHelper hasGameEngineView:window depth:0] || 
            [LeftPanWindowHelper hasGameEngineView:topVC.view depth:0]) {
            return NO;
        }
    }

    CGPoint rawVel = [self.pan rawVelocityInView:self.pan.view];
    if (rawVel.x >= kLPVGestureStartVelocityThreshold) return NO;
    if (fabs(rawVel.x) <= fabs(rawVel.y) * 1.3) return NO;

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
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end

#pragma mark - Global Runtime Hooks & Window Injection

static UIInterfaceOrientationMask (*orig_VC_supportedInterfaceOrientations)(id, SEL);
static UIInterfaceOrientationMask swiz_VC_supportedInterfaceOrientations(UIViewController *self, SEL _cmd) {
    if (g_forceAllowPortrait) {
        return UIInterfaceOrientationMaskPortrait;
    }
    if (orig_VC_supportedInterfaceOrientations) {
        return orig_VC_supportedInterfaceOrientations(self, _cmd);
    }
    return UIInterfaceOrientationMaskAll;
}

static BOOL (*orig_VC_shouldAutorotate)(id, SEL);
static BOOL swiz_VC_shouldAutorotate(UIViewController *self, SEL _cmd) {
    if (g_forceAllowPortrait) return YES;
    if (orig_VC_shouldAutorotate) return orig_VC_shouldAutorotate(self, _cmd);
    return YES;
}

static UIDeviceOrientation (*orig_Device_orientation)(id, SEL);
static UIDeviceOrientation swiz_Device_orientation(UIDevice *self, SEL _cmd) {
    if (g_forceAllowPortrait) return UIDeviceOrientationPortrait;
    if (orig_Device_orientation) return orig_Device_orientation(self, _cmd);
    return UIDeviceOrientationPortrait;
}

static UIInterfaceOrientation (*orig_App_statusBarOrientation)(id, SEL);
static UIInterfaceOrientation swiz_App_statusBarOrientation(UIApplication *self, SEL _cmd) {
    if (g_forceAllowPortrait) return UIInterfaceOrientationPortrait;
    if (orig_App_statusBarOrientation) return orig_App_statusBarOrientation(self, _cmd);
    return UIInterfaceOrientationPortrait;
}

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
    Class vcClass = [UIViewController class];
    Method mSupported = class_getInstanceMethod(vcClass, @selector(supportedInterfaceOrientations));
    if (mSupported) {
        orig_VC_supportedInterfaceOrientations = (UIInterfaceOrientationMask (*)(id, SEL))method_getImplementation(mSupported);
        method_setImplementation(mSupported, (IMP)swiz_VC_supportedInterfaceOrientations);
    }
    Method mAuto = class_getInstanceMethod(vcClass, @selector(shouldAutorotate));
    if (mAuto) {
        orig_VC_shouldAutorotate = (BOOL (*)(id, SEL))method_getImplementation(mAuto);
        method_setImplementation(mAuto, (IMP)swiz_VC_shouldAutorotate);
    }

    Class devClass = [UIDevice class];
    Method mDevOri = class_getInstanceMethod(devClass, @selector(orientation));
    if (mDevOri) {
        orig_Device_orientation = (UIDeviceOrientation (*)(id, SEL))method_getImplementation(mDevOri);
        method_setImplementation(mDevOri, (IMP)swiz_Device_orientation);
    }

    Class appClass = [UIApplication class];
    Method mAppOri = class_getInstanceMethod(appClass, @selector(statusBarOrientation));
    if (mAppOri) {
        orig_App_statusBarOrientation = (UIInterfaceOrientation (*)(id, SEL))method_getImplementation(mAppOri);
        method_setImplementation(mAppOri, (IMP)swiz_App_statusBarOrientation);
    }

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
