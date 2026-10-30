import LeanNativeShell.ObjC

/-! # LeanNativeShell.App: `LNApp.m`, `main`, the app delegate and the scene delegate -/

namespace LeanNativeShell

set_option maxRecDepth 8000 in
def appFile : List Stmt := [
    .pp "#import \"LeanNativeShell.h\"",
    .blank,
    .l "// The whole iOS app of a LeanNative native app: the generic renderer around whatever view Lean returns. An",
    .l "// app ships no code of its own here; its name comes from Info.plist (`CFBundleDisplayName`). While the",
    .l "// scene is not active the window is covered (app-switcher snapshots never show it); under Mac Catalyst",
    .l "// only while it is in the background, since a Mac window is inactive whenever another app is in front.",
    .blank,
    b "int main(int argc, char *argv[]) {" [
        b "@autoreleasepool {" [
            .l "return UIApplicationMain(argc, argv, nil, NSStringFromClass(LNAppDelegate.class));"]],
    .blank,
    .l "@implementation LNAppDelegate",
    .blank,
    b "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {" [
        .l "// before launch ends, as iOS requires: the handlers of the app's background tasks",
        .l "[LNBackgroundTasks.shared registerLaunch];",
        .l "// a scene saved by an earlier build of the app (a SwiftUI shell) comes back with that build's delegate",
        .l "// (SwiftUI.AppSceneDelegate, which the system still provides) and would stay an empty window: it gets",
        .l "// the shell's delegate instead",
        .l "[NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification object:nil queue:nil",
        b "                                            usingBlock:^(NSNotification *note) {" [
            .l "UIScene *scene = note.object;",
            .l "// only the app's own window scene: system scenes (the keyboard's) connect in-process too",
            .l "if ([scene.delegate isKindOfClass:LNSceneDelegate.class] || ![scene isKindOfClass:UIWindowScene.class] ||",
            .l "    ![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) return;",
            .l "LNSceneDelegate *delegate = [LNSceneDelegate new];",
            .l "scene.delegate = delegate;",
            .l "[delegate scene:scene willConnectToSession:scene.session options:(UISceneConnectionOptions *_Nonnull)nil];"] "}];",
        .l "[LNStore.shared start];",
        .l "return YES;"],
    .blank,
    .l "- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session",
    b "                              options:(UISceneConnectionOptions *)options {" [
        .l "UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@\"Default\" sessionRole:session.role];",
        .l "config.delegateClass = LNSceneDelegate.class;",
        .l "return config;"],
    .blank,
    .l "@end",
    .blank,
    b "@implementation LNSceneDelegate {" [
        .l "UIView *_cover;"],
    .blank,
    b "- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {" [
        .l "self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];",
        .l "self.window.rootViewController = [LNRootController new];",
        .l "_cover = [UIView new];",
        .l "_cover.backgroundColor = UIColor.systemBackgroundColor;",
        .l "_cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;",
        .pp "#if TARGET_OS_MACCATALYST",
        .l "// on a Mac the window is resizable: never narrower or shorter than a phone screen, the layout's design size",
        .l "((UIWindowScene *)scene).sizeRestrictions.minimumSize = CGSizeMake(390, 640);",
        .pp "#endif",
        .l "[self.window makeKeyAndVisible];",
        .l "[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(capturedChanged)",
        .l "                                           name:UIScreenCapturedDidChangeNotification object:nil];",
        .l "[self phase:@\"inactive\"];"],
    .blank,
    .l "- (void)sceneDidBecomeActive:(UIScene *)scene { [self phase:@\"active\"]; }",
    .l "- (void)sceneWillResignActive:(UIScene *)scene { [self phase:@\"inactive\"]; }",
    .l "- (void)sceneWillEnterForeground:(UIScene *)scene { [self phase:@\"inactive\"]; }",
    .l "- (void)sceneDidEnterBackground:(UIScene *)scene { [self phase:@\"background\"]; }",
    .blank,
    b "- (void)phase:(NSString *)name {" [
        .pp "#if TARGET_OS_MACCATALYST",
        .l "// a Mac window is inactive whenever another app is in front, and has no app-switcher snapshot: it is",
        .l "// covered only in the background (the app hidden, or every window closed or minimised)",
        .l "BOOL covered = [name isEqualToString:@\"background\"];",
        .pp "#else",
        .l "BOOL covered = ![name isEqualToString:@\"active\"];",
        .pp "#endif",
        .blk [("if (!covered) {", [
              .l "[_cover removeFromSuperview];"]), ("} else if (self.window) {", [
              .l "_cover.frame = self.window.bounds;",
              .l "[self.window addSubview:_cover];"])] "}",
        .l "[LNStore.shared system:@{@\"scene\": name}];"],
    .blank,
    b "- (void)capturedChanged {" [
        .l "[LNStore.shared system:@{@\"captured\": @(self.window.windowScene.screen.isCaptured)}];"],
    .blank,
    .l "@end"]

end LeanNativeShell
