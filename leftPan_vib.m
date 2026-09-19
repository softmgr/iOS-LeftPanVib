#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------
// CONFIGURATION (Constants for easy maintenance)
// ---------------------------------------------------------

// 1. Trigger Zones
#define kLPVPortraitZoneRatio (2.0 / 3.0)
#define kLPVLandscapeZoneWidth 60.0

// 2. Intent Thresholds
#define kLPVGestureStartVelocityThreshold -40.0

// 3. Fallback Success Thresholds
#define kLPVFallbackSuccessTranslation 100.0     
#define kLPVFallbackSuccessVelocity 300.0        
#define kLPVFallbackMinFlickTranslation 20.0     

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

// 核心边界分析，新增了“特定应用白名单”机制
+ (BOOL)canGoBack:(UIViewController *)topVC {
    // 1. 白名单检查（如百度贴吧、微信等自研路由巨头）
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.baidu.tieba"] || [bundleID isEqualToString:@"com.tencent.xin"]) {
        return YES; // 无视导航栈状态，直接放行手势探测
    }
    
    // 2. 原生标准检查
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
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        NSArray *ipadOrientations = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UISupportedInterfaceOrientations~ipad"];
        if (ipadOrientations) supportedOrientations = ipadOrientations;
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

#pragma mark - Runtime Gesture Target-Action Extraction

// 核心函数：利用 C 语言级的指针内存偏移计算，强行越权提取宿主手势内部 Target 的真实 action 指针
- (BOOL)extractAndHijackActionFromGesture:(UIGestureRecognizer *)gesture {
    @try {
        NSArray *targets = [gesture valueForKey:@"targets"];
        if (!targets || targets.count == 0) return NO;
        
        // 获取私有的 UIGestureRecognizerTarget 实例
        id targetObj = targets.firstObject; 
        id target = [targetObj valueForKey:@"target"];
        if (!target) return NO;
        
        // 查找私有变量 _action 的内存偏移量
        Ivar actionIvar = class_getInstanceVariable([targetObj class], "_action");
        if (!actionIvar) return NO;
        
        // 关键操作：强转为 uint8_t 字节指针，基于基址加上偏移量读取 SEL
        SEL action = *(SEL *)((uint8_t *)(__bridge void *)targetObj + ivar_getOffset(actionIvar));
        
        if (action && [target respondsToSelector:action]) {
            self.systemTarget = target;
            self.systemAction = action;
            self.useFallbackMode = NO; // 接管成功，移交系统或宿主自行处理动画
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

// 向上遍历视图树，搜索带有返回属性的手势
- (BOOL)searchAndHijackHostReturnGestureInView:(UIView *)view {
    UIView *currentView = view;
    while (currentView) {
        for (UIGestureRecognizer *g in currentView.gestureRecognizers) {
            if (!g.enabled) continue;
            
            // 匹配条件1：系统的左侧边缘滑动手势
            BOOL isLeftEdgePan = [g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]] && 
                                 (((UIScreenEdgePanGestureRecognizer *)g).edges == UIRectEdgeLeft);
            
            // 匹配条件2：名称包含相关字眼的面版滑动（应对各类 TBCPopGestureRecognizer 等魔改库）
            NSString *className = NSStringFromClass([g class]);
            BOOL isCustomPop = ([g isKindOfClass:[UIPanGestureRecognizer class]] && 
                                ([className containsString:@"Pop"] || 
                                 [className containsString:@"Back"] || 
                                 [className containsString:@"Transition"]));
            
            if (isLeftEdgePan || isCustomPop) {
                if ([self extractAndHijackActionFromGesture:g]) {
                    return YES; // 成功窃取！
                }
            }
        }
        currentView = currentView.superview;
    }
    return NO;
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

        BOOL hijackSuccess = NO;

        // 1. 尝试窃取 iOS 原生的导航手势
        if (nav && !isLandscape) {
            hijackSuccess = [self extractAndHijackActionFromGesture:nav.interactivePopGestureRecognizer];
        }
        
        // 2. 如果原生手势不存在或不可用，且当前为非横屏，启动“白名单”专属的深度搜捕机制
        if (!hijackSuccess && !isLandscape) {
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
            if ([bundleID isEqualToString:@"com.baidu.tieba"] || [bundleID isEqualToString:@"com.tencent.xin"]) {
                // 优先在当前 VC 视图中搜寻，再搜寻全屏幕 Window 层
                hijackSuccess = [self searchAndHijackHostReturnGestureInView:topVC.view] || 
                                [self searchAndHijackHostReturnGestureInView:window];
            }
        }
    }

    if (!self.useFallbackMode && self.systemTarget) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        // 直接将翻转后的参数喂给宿主的接收器，宿主会以为这是来自屏幕左侧的标准原生滑动
        [self.systemTarget performSelector:self.systemAction withObject:pan];
        #pragma clang diagnostic pop
        
        if (pan.state == UIGestureRecognizerStateBegan) {
            dispatch_async(dispatch_get_main_queue(), ^{
                id<UIViewControllerTransitionCoordinator> coordinator = topVC.transitionCoordinator ?: nav.transitionCoordinator;
                if (coordinator && [coordinator initiallyInteractive]) {
                    if (@available(iOS 10.0, *)) {
                        [coordinator notifyWhenInteractionEndsUsingBlock:^(id<UIViewControllerTransitionCoordinatorContext> context) {
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
            CGFloat requiredTrans = isLandscape ? kLPVFallbackSuccessTranslation : (screenWidth * 0.5);
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
    if (@available(iOS 13.0, *)) {
        isLandscape = UIInterfaceOrientationIsLandscape(window.windowScene.interfaceOrientation);
    } else {
        isLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    }

    CGPoint loc = [self.pan locationInView:self.pan.view];
    CGFloat screenWidth = self.pan.view.bounds.size.width;
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];

    if (isLandscape) {
        if ([LeftPanWindowHelper isGameViewController:topVC]) return NO;
        if (loc.x < screenWidth - kLPVLandscapeZoneWidth) return NO;
    } else {
        if (loc.x < screenWidth * kLPVPortraitZoneRatio) return NO;
    }

    CGPoint rawVel = [self.pan rawVelocityInView:self.pan.view];
    if (rawVel.x >= kLPVGestureStartVelocityThreshold) return NO;
    if (fabs(rawVel.x) <= fabs(rawVel.y) * 1.3) return NO;

    if (![LeftPanWindowHelper canGoBack:topVC]) return NO;

    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer == self.pan) {
        if ([otherGestureRecognizer isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return NO;
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
