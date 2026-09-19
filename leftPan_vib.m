#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char kLeftPanHelperKey;

@interface LeftPanBackHelper : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UINavigationController *nav;
@property (nonatomic, assign) BOOL hasTriggered;
@end

@implementation LeftPanBackHelper

- (instancetype)initWithNavController:(UINavigationController *)nav {
    self = [super init];
    if (self) {
        _nav = nav;
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!self.nav || self.nav.viewControllers.count <= 1) return;

    CGPoint translation = [pan translationInView:pan.view];
    CGPoint velocity = [pan velocityInView:pan.view];

    if (pan.state == UIGestureRecognizerStateBegan) {
        self.hasTriggered = NO;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        // 从右往左滑动超过 60pt，且主要是水平滑动时立即触发返回
        if (!self.hasTriggered && translation.x < -60 && (fabs(translation.x) > fabs(translation.y) * 1.2)) {
            self.hasTriggered = YES;
            [self executePop];
        }
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        // 手指抬起时，若达到甩动速度阈值也触发返回
        if (!self.hasTriggered && (translation.x < -30 || velocity.x < -350) && (fabs(translation.x) > fabs(translation.y))) {
            self.hasTriggered = YES;
            [self executePop];
        }
        self.hasTriggered = NO;
    }
}

- (void)executePop {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.nav.viewControllers.count > 1) {
            // iOS 自带键盘同款弱震动反馈 (Light 档位)
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback prepare];
            [feedback impactOccurred];

            [self.nav popViewControllerAnimated:YES];
        }
    });
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;

    // 1. 仅在二级及以上页面生效（根目录不触发）
    if (!self.nav || self.nav.viewControllers.count <= 1) {
        return NO;
    }

    // 2. 限制触摸起点区域：必须在屏幕中间至右边缘（屏幕宽度的 40% ~ 100%）
    CGPoint location = [pan locationInView:pan.view];
    CGFloat screenWidth = pan.view.bounds.size.width;
    if (location.x < screenWidth * 0.40) {
        return NO;
    }

    // 3. 必须是向左划动的意图（X轴负向速度大于Y轴速度，防止误触列表上下滚动）
    CGPoint velocity = [pan velocityInView:pan.view];
    if (velocity.x >= -30) {
        return NO;
    }
    if (fabs(velocity.x) <= fabs(velocity.y) * 1.2) {
        return NO;
    }

    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 允许与页面内的纵向列表滚动同时识别，避免滑动手势被阻断
    if ([otherGestureRecognizer.view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)otherGestureRecognizer.view;
        // 如果遇到横向滚动视图（如横向轮播图、横向图片集），优先让横向视图滚动
        if (sv.contentSize.width > sv.bounds.size.width + 20) {
            return NO;
        }
        return YES;
    }
    return NO;
}

@end

#pragma mark - Hook NavigationController

static void (*orig_UINavigationController_viewDidAppear)(id, SEL, BOOL);

static void swiz_UINavigationController_viewDidAppear(UINavigationController *self, SEL _cmd, BOOL animated) {
    orig_UINavigationController_viewDidAppear(self, _cmd, animated);

    if ([self isKindOfClass:[UINavigationController class]] && self.view) {
        LeftPanBackHelper *helper = objc_getAssociatedObject(self, &kLeftPanHelperKey);
        if (!helper) {
            helper = [[LeftPanBackHelper alloc] initWithNavController:self];
            objc_setAssociatedObject(self, &kLeftPanHelperKey, helper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:helper action:@selector(handlePan:)];
            pan.delegate = helper;
            pan.cancelsTouchesInView = NO;
            [self.view addGestureRecognizer:pan];
        }
    }
}

__attribute__((constructor)) static void init_leftPanVib(void) {
    Class navClass = [UINavigationController class];
    Method m = class_getInstanceMethod(navClass, @selector(viewDidAppear:));
    if (m) {
        orig_UINavigationController_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swiz_UINavigationController_viewDidAppear);
    }
}
