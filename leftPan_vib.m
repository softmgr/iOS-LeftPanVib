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

+ (BOOL)canGoBack:(UIViewController *)topVC window:(UIWindow *)window isLandscape:(BOOL)isLandscape {
    if (isLandscape) return YES;
    if (!topVC) return NO;
    
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

+ (void)dispatchTouchToWindow:(UIWindow *)window atPoint:(CGPoint)pt {
    UIView *hit = [window hitTest:pt withEvent:nil];
    if (hit) {
        [hit touchesBegan:[NSSet set] withEvent:nil];
        [hit touchesEnded:[NSSet set] withEvent:nil];
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

static void unlockRNOrientation(void) {
    Class oriClass = NSClassFromString(@"Orientation");
    if (!oriClass) {
        oriClass = NSClassFromString(@"OrientationLocker");
    }
    if (oriClass) {
        SEL setOriSel = NSSelectorFromString(@"setOrientation:");
        Method m = class_getClassMethod(oriClass, setOriSel);
        if (m) {
            void (*impl)(id, SEL, UIInterfaceOrientationMask) = (void (*)(id, SEL, UIInterfaceOrientationMask))method_getImplementation(m);
            if (impl) {
                impl(oriClass, setOriSel, UIInterfaceOrientationMaskAll);
            }
        }
        SEL lockPortSel = NSSelectorFromString(@"lockToPortrait");
        if ([oriClass respondsToSelector:lockPortSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [oriClass performSelector:lockPortSel];
            #pragma clang diagnostic pop
        }
    }
}

// Universal exit full-screen mode for React Native (RCTVideo), Bilibili, and native players
+ (BOOL)exitVideoFullScreen:(UIViewController *)topVC window:(UIWindow *)window {
    BOOL didTrigger = NO;
    
    // 1. Selector Reflection on View Controllers
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
    
    // 2. View Hierarchy Scan for Player Views (e.g., react_native_video.RCTVideo, AVPlayer, ZFPlayer)
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
            
            // Critical: Matches React Native's standard 'setIsFullscreen:' setter
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
    
    // 3. Native UIButton search inside player controls
    if (!didTrigger) {
        UIView *searchRoot = topVC.view ?: window;
        if (searchRoot) {
            didTrigger = [self searchAndClickPlayerExitButton:searchRoot window:window];
        }
    }
    
    // 4. Universal Physical Touch Dispatch (Target Top-Left Back Button for RCTView, Flutter, etc.)
    if (window) {
        CGFloat safeLeft = 0.0;
        CGFloat safeTop = 0.0;
        if (@available(iOS 11.0, *)) {
            if (window.safeAreaInsets.left > 0) safeLeft = window.safeAreaInsets.left;
            if (window.safeAreaInsets.top > 0) safeTop = window.safeAreaInsets.top;
        }
        CGPoint ptTopLeft = CGPointMake(safeLeft + 35.0, safeTop + 25.0);
        
        CGFloat screenW = window.bounds.size.width;
        CGFloat screenH = window.bounds.size.height;
        CGPoint centerPt = CGPointMake(screenW * 0.5, screenH * 0.5);
        [self dispatchTouchToWindow:window atPoint:centerPt];
        
        [self dispatchTouchToWindow:window atPoint:ptTopLeft];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self dispatchTouchToWindow:window atPoint:ptTopLeft];
        });
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

// Breakthrough Force Rotation Engine (Bypasses all app/framework orientation locks)
- (void)forcePortraitOrientation {
    g_forceAllowPortrait = YES;
    unlockRNOrientation();

    UIViewController *topVC = [LeftPanWindowHelper findTopViewController:self.window.rootViewController];
    if (@available(iOS 16.0, *)) {
        if (topVC) [topVC setNeedsUpdateOfSupportedInterfaceOrientations];
        if (self.window.rootViewController) [self.window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    }

    // 1. Invocation-based low-level private orientation assignment (bypasses iOS 16 KVC traps)
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

    // 2. Modern WindowScene Geometry Request
    if (@available(iOS 16.0, *)) {
        UIWindowScene *scene = (UIWindowScene *)self.window.windowScene;
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

    // 3. Keep orientation privilege alive across the full animation window
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
    
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = log;
    
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
        
#if ENABLE_DEBUG_LOGGING
        [LeftPanWindowHelper captureDebugInfoToClipboard:topVC window:window isLandscape:isLandscape];
#endif
        
        self.systemTarget = nil;
        self.systemAction = NULL;
        self.useFallbackMode = YES;

        if (nav && !isLandscape) {
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
                                #if !ENABLE_DEBUG_LOGGING
                                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                                [feedback prepare];
                                [feedback impactOccurred];
                                #endif
#endif
                            }
                        }];
                    }
                }
            });
        }
    } else {
        [self handleFallbackPan:pan isLandscape:isLandscape topVC:topVC];
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
                #if !ENABLE_DEBUG_LOGGING
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback prepare];
                [feedback impactOccurred];
                #endif
#endif
                if (isAnyLandscape) {
                    BOOL videoHandled = [LeftPanWindowHelper exitVideoFullScreen:topVC window:self.window];
                    [self forcePortraitOrientation];
                    
                    // Watchdog Fallback: If not handled by video exit, pop the landscape container directly after 150ms
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

#if ENABLE_DEBUG_LOGGING
    return YES;
#endif

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

    if (!isSpecialApp_Huya() && !isSpecialApp_Amap()) {
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
        
#if ENABLE_DEBUG_LOGGING
        return YES;
#endif
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
#if ENABLE_DEBUG_LOGGING
    return YES;
#endif
    return NO;
}

@end

#pragma mark - Global Runtime Hooks & Window Injection

static UIInterfaceOrientationMask (*orig_VC_supportedInterfaceOrientations)(id, SEL);
static UIInterfaceOrientationMask swiz_VC_supportedInterfaceOrientations(UIViewController *self, SEL _cmd) {
    if (g_forceAllowPortrait) {
        return UIInterfaceOrientationMaskAll;
    }
    if (orig_VC_supportedInterfaceOrientations) {
        return orig_VC_supportedInterfaceOrientations(self, _cmd);
    }
    return UIInterfaceOrientationMaskAll;
}

static BOOL (*orig_VC_shouldAutorotate)(id, SEL);
static BOOL swiz_VC_shouldAutorotate(UIViewController *self, SEL _cmd) {
    if (g_forceAllowPortrait) {
        return YES;
    }
    if (orig_VC_shouldAutorotate) {
        return orig_VC_shouldAutorotate(self, _cmd);
    }
    return YES;
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
    // 1. Swizzle UIViewController orientation privileges to break app-level portrait locks
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

    // 2. Global Window Injection
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
