#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char kWindowHelperKey;

@interface LeftPanWindowHelper : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@property (nonatomic, assign) BOOL hasTriggered;
@end

@implementation LeftPanWindowHelper

- (instancetype)initWithWindow:(UIWindow *)window {
    self = [super init];
    if (self) {
        _window = window;
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        _pan.delegate = self;
        // 关键：触发后立即中断并取消底层 B站自带的滑动评论区/进度条事件
        _pan.cancelsTouchesInView = YES;
        _pan.delaysTouchesBegan = NO;
        [window addGestureRecognizer:_pan];
    }
    return self;
}

#pragma mark - 控制器递归查找

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

#pragma mark - 手势与震动处理

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.hasTriggered = NO;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (self.hasTriggered) return;
        CGPoint trans = [pan translationInView:pan.view];
        // 左滑位移达到 40pt 即瞬间激活返回并震动
        if (trans.x < -40.0) {
            self.hasTriggered = YES;
            [self performBack];
        }
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        if (!self.hasTriggered) {
            CGPoint trans = [pan translationInView:pan.view];
            CGPoint vel = [pan velocityInView:pan.view];
            if (trans.x < -25.0 || vel.x < -300.0) {
                self.hasTriggered = YES;
                [self performBack];
            }
        }
        self.hasTriggered = NO;
    }
}

- (void)performBack {
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    if (!topVC) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // iOS 自带键盘输入时的清脆弱震感 (Light)
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback prepare];
        [feedback impactOccurred];

        UINavigationController *nav = [LeftPanWindowHelper findNavControllerFor:topVC];
        if (nav && nav.viewControllers.count > 1) {
            [nav popViewControllerAnimated:YES];
            return;
        }

        if (topVC.presentingViewController) {
            [topVC dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

#pragma mark - UIGestureRecognizerDelegate (手势排他与冲突解决)

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.pan) return YES;

    CGPoint loc = [self.pan locationInView:self.pan.view];
    CGFloat screenWidth = self.pan.view.bounds.size.width;

    // 1. 触摸起点限制：必须在屏幕中间到右边缘（屏幕宽度的 40% ~ 100%）
    if (loc.x < screenWidth * 0.40) {
        return NO;
    }

    // 2. 意图判断：必须是向左划动（X轴负向速度），且水平意图明显大于垂直滑动（防止看视频上下翻评论误触）
    CGPoint vel = [self.pan velocityInView:self.pan.view];
    if (vel.x >= -40) {
        return NO;
    }
    if (fabs(vel.x) <= fabs(vel.y) * 1.3) {
        return NO;
    }

    // 3. 页面判断：如果当前就在主页/根页面（无法再返回），不拦截，放行应用自带功能
    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    if (![LeftPanWindowHelper canGoBack:topVC]) {
        return NO;
    }

    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer == self.pan) {
        // 放行系统自带的从屏幕最左边缘右滑返回手势
        if ([otherGestureRecognizer isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
            return NO;
        }
        // 核心：强制 B站内所有自带手势（横向滚评论区、播放器内滑动）等待并让位给此返回手势
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 互斥响应，防止在返回的同时还在背景里滚评论
    return NO;
}

@end

#pragma mark - 全局窗口注入与监听

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
    // 监听全局 KeyWindow 切换通知
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[UIWindow class]]) {
            attachHelperToWindow((UIWindow *)note.object);
        }
    }];

    // Hook UIWindow makeKeyAndVisible
    Class winClass = [UIWindow class];
    Method m = class_getInstanceMethod(winClass, @selector(makeKeyAndVisible));
    if (m) {
        orig_UIWindow_makeKeyAndVisible = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swiz_UIWindow_makeKeyAndVisible);
    }
}
