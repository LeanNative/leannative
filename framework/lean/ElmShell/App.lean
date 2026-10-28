import ElmShell.ObjC

/-! # ElmShell.App: `ELApp.m`, `main`, the app delegate and the scene delegate -/

namespace ElmShell

set_option maxRecDepth 8000 in
def appFile : List Stmt := [
    .pp "#import \"ElmLeanShell.h\"",
    .blank,
    .l "// The whole iOS app of an ElmLean native app: the generic renderer around whatever view Lean returns. An",
    .l "// app ships no code of its own here; its name comes from Info.plist (`CFBundleDisplayName`). While the",
    .l "// scene is not active the window is covered (app-switcher snapshots never show it).",
    .blank,
    b "int main(int argc, char *argv[]) {" [
        b "@autoreleasepool {" [
            .l "return UIApplicationMain(argc, argv, nil, NSStringFromClass(ELAppDelegate.class));"]],
    .blank,
    .l "@implementation ELAppDelegate",
    .blank,
    b "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {" [
        .l "// before launch ends, as iOS requires: the handlers of the app's background tasks",
        .l "[ELBackgroundTasks.shared registerLaunch];",
        .l "// a scene saved by an earlier build of the app (a SwiftUI shell) comes back with that build's delegate",
        .l "// (SwiftUI.AppSceneDelegate, which the system still provides) and would stay an empty window: it gets",
        .l "// the shell's delegate instead",
        .l "[NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification object:nil queue:nil",
        b "                                            usingBlock:^(NSNotification *note) {" [
            .l "UIScene *scene = note.object;",
            .l "// only the app's own window scene: system scenes (the keyboard's) connect in-process too",
            .l "if ([scene.delegate isKindOfClass:ELSceneDelegate.class] || ![scene isKindOfClass:UIWindowScene.class] ||",
            .l "    ![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) return;",
            .l "ELSceneDelegate *delegate = [ELSceneDelegate new];",
            .l "scene.delegate = delegate;",
            .l "[delegate scene:scene willConnectToSession:scene.session options:(UISceneConnectionOptions *_Nonnull)nil];"] "}];",
        .l "[ELStore.shared start];",
        .l "return YES;"],
    .blank,
    .l "- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session",
    b "                              options:(UISceneConnectionOptions *)options {" [
        .l "UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@\"Default\" sessionRole:session.role];",
        .l "config.delegateClass = ELSceneDelegate.class;",
        .l "return config;"],
    .blank,
    .l "@end",
    .blank,
    b "@implementation ELSceneDelegate {" [
        .l "UIView *_cover;"],
    .blank,
    b "- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {" [
        .l "self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];",
        .l "self.window.rootViewController = [ELRootController new];",
        .l "_cover = [UIView new];",
        .l "_cover.backgroundColor = UIColor.systemBackgroundColor;",
        .l "_cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;",
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
        .blk [("if ([name isEqualToString:@\"active\"]) {", [
              .l "[_cover removeFromSuperview];"]), ("} else if (self.window) {", [
              .l "_cover.frame = self.window.bounds;",
              .l "[self.window addSubview:_cover];"])] "}",
        .l "[ELStore.shared system:@{@\"scene\": name}];"],
    .blank,
    b "- (void)capturedChanged {" [
        .l "[ELStore.shared system:@{@\"captured\": @(self.window.windowScene.screen.isCaptured)}];"],
    .blank,
    .l "@end"]

end ElmShell
