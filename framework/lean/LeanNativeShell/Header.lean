import LeanNativeShell.Grammar
import LeanNativeShell.Capabilities

/-! # LeanNativeShell.Header: `LeanNativeShell.h`, the one header of the shell

The capability table in the doc comment of `LNCapabilities` and the event functions come from the tables. -/

namespace LeanNativeShell

set_option maxRecDepth 8000 in
def headerFile : List Stmt :=
  [
    .l "// The native shell of a LeanNative app: one header for the store, the node decoder, the renderer and the",
    .l "// capabilities.",
    .pp "#import <UIKit/UIKit.h>",
    .pp "#import \"leannative.h\"",
    .blank,
    .l "NS_ASSUME_NONNULL_BEGIN",
    .blank,
    .l "typedef NSArray<NSNumber *> LNPath;",
    .blank] ++
  capabilitiesDoc.map (fun l => .l (if l.isEmpty then "///" else "/// " ++ l)) ++
  [
    .l "@interface LNCapabilities : NSObject",
    .l "- (void)run:(NSString *)name args:(NSDictionary *)args answer:(void (^)(NSDictionary *result))answer;",
    .l "@end",
    .blank,
    .l "/// Background tasks (`bgtask.*`): `registerLaunch` registers a launch handler for every identifier in",
    .l "/// Info.plist's `BGTaskSchedulerPermittedIdentifiers`; iOS requires it before the app finishes launching.",
    .l "@interface LNBackgroundTasks : NSObject",
    .l "+ (instancetype)shared;",
    .l "- (void)registerLaunch;",
    .l "@end",
    .blank,
    .l "/// The app's state as the shell sees it: the last view Lean returned (decoded) and its `seq`.",
    .l "@interface LNStore : NSObject",
    .l "+ (instancetype)shared;",
    .l "@property (nonatomic, readonly) NSDictionary *view;",
    .l "@property (nonatomic, readonly) NSInteger seq;",
    .l "@property (nonatomic, readonly, nullable) NSString *failure;",
    .l "/// Called on the main thread after every reply.",
    .l "@property (nonatomic, copy, nullable) void (^onChange)(void);",
    .l "/// Boots Lean and shows the first view; once (later calls do nothing).",
    .l "- (void)start;",
    .l "- (void)send:(LNPath *)path event:(NSDictionary *)event;",
    .l "- (void)drain;",
    .l "- (void)system:(NSDictionary *)event;",
    .l "@end",
    .blank,
    .l "/// The events a renderer sends (PROTOCOL.md, \"Client → CLI\")."] ++
  events.map (fun e => .l (eventSig e ++ ";")) ++
  [
    .blank,
    .l "/// A node of the view tree (PROTOCOL.md, \"Node grammar\") with every field present: absent or ill-typed",
    .l "/// fields take their defaults, an enum outside its values its default, an unknown `t` becomes",
    .l "/// `{\"t\":\"unknown\",\"name\":t}`. Children are under `c`, decoded the same way.",
    .l "NSDictionary *LNDecode(id _Nullable json);",
    .l "/// Nodes that take no room in a layout: presentations and spacers.",
    .l "BOOL LNIsOverlay(NSDictionary *node);",
    .blank,
    .l "/// The whole window's content: the generic renderer around whatever view Lean returns.",
    .l "@interface LNRootController : UIViewController",
    .l "@end",
    .blank,
    .l "@interface LNAppDelegate : UIResponder <UIApplicationDelegate>",
    .l "@end",
    .blank,
    .l "@interface LNSceneDelegate : UIResponder <UIWindowSceneDelegate>",
    .l "@property (nonatomic, strong, nullable) UIWindow *window;",
    .l "@end",
    .blank,
    .l "NS_ASSUME_NONNULL_END"]

end LeanNativeShell
