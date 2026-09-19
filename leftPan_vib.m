#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@implementation UINavigationController (VibePop)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [self class];
        Method orig = class_getInstanceMethod(cls, @selector(viewDidLoad));
        Method swiz = class_getInstanceMethod(cls, @selector(vibe_viewDidLoad));
        method_exchangeImplementations(orig, swiz);
    });
}

- (void)vibe_viewDidLoad {
    [self vibe_viewDidLoad];
    if (self.interactivePopGestureRecognizer) {
        [self.interactivePopGestureRecognizer addTarget:self action:@selector(vibe_handlePop:)];
    }
}

- (void)vibe_handlePop:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
}

@end
