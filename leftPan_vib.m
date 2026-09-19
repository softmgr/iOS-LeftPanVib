#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void vibe_handlePop(id self, SEL _cmd, UIGestureRecognizer *gesture) {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [generator prepare];
            [generator impactOccurred];
        });
    }
}

static void (*orig_viewDidLoad)(id, SEL);

static void swiz_viewDidLoad(UIViewController *self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    
    if ([self isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)self;
        if (nav.interactivePopGestureRecognizer) {
            // 避免重复添加 target 导致单次手势震动多次
            [nav.interactivePopGestureRecognizer removeTarget:nav action:@selector(vibe_handlePop:)];
            [nav.interactivePopGestureRecognizer addTarget:nav action:@selector(vibe_handlePop:)];
        }
    }
}

__attribute__((constructor)) static void init_vib(void) {
    Class navClass = [UINavigationController class];
    
    class_addMethod(navClass, @selector(vibe_handlePop:), (IMP)vibe_handlePop, "v@:@");
    
    Method origMethod = class_getInstanceMethod(navClass, @selector(viewDidLoad));
    if (origMethod) {
        orig_viewDidLoad = (void (*)(id, SEL))method_getImplementation(origMethod);
        method_setImplementation(origMethod, (IMP)swiz_viewDidLoad);
    }
}
