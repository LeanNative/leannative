import LeanNativeShell.ObjC
import LeanNative.Json

/-!
# LeanNativeShell.Grammar

The node grammar of PROTOCOL.md as one table, the source of everything in the shell that follows the
grammar: the decoding of a node (`LNDecode`, `LeanNativeShell.Node`), the renderer's dispatch with one arm per
kind (`LNBuild`, `LeanNativeShell.Render`), which kinds take no room in a layout (`LNIsOverlay`), the values of the
three string enums and the events. `LeanNativeShell.Check` holds the table to `Wire.toJson` and
`Event.fromJson?`.
-/

namespace LeanNativeShell
open LeanNative

/-- How a field crosses the wire. -/
inductive FTy where
  | str
  /-- a `Bool`, `dflt` when absent -/
  | bool (dflt : Bool := false)
  | int
  | strs
  /-- one of a string enum's values (`stringEnums`), `dflt` when absent or unknown -/
  | enum (name : String) (dflt : String)
  /-- the children, under the wire key `c` -/
  | kids
  deriving BEq, Repr

structure Field where
  /-- the wire key (`c` for the children) -/
  key : String
  ty : FTy

structure NodeKind where
  /-- the wire tag `t` -/
  tag : String
  fields : List Field := []
  /-- the renderer's arm (`LNBuild`): it builds the views of `box` for the node `n` at `path`, and sets
  `box.update` when a new node of the same kind can update them in place -/
  render : List Stmt
  /-- presentations and spacers: they take no room in a screen's layout -/
  overlay : Bool := false

def str (k : String) : Field := { key := k, ty := .str }
def bool (k : String) (dflt := false) : Field := { key := k, ty := .bool dflt }
def int (k : String) : Field := { key := k, ty := .int }
def strs (k : String) : Field := { key := k, ty := .strs }
def enum (k name dflt : String) : Field := { key := k, ty := .enum name dflt }
def kids : Field := { key := "c", ty := .kids }

/-- The key any node may carry besides its row's fields: `Html.identified`'s identifier, which the shell
sets as the node's `accessibilityIdentifier` (`LNIdentify`). -/
def idKey : String := "id"

/-- The other key any node may carry: `Html.decorated`'s `Decor`, an object with these fields (`LeanNativeShell.Check`
holds them to `Decor.toJson`). The shell decodes it on every node, absent fields as their defaults, so a
renderer reads `n[@"decor"][@"tone"]` whatever the node. -/
def decorKey : String := "decor"

def decorFields : List Field :=
  [{ key := "tone", ty := .enum "Tone" "standard" }, { key := "mono", ty := .bool }, { key := "badge", ty := .bool },
   { key := "centered", ty := .bool }, { key := "symbol", ty := .str }, { key := "chevron", ty := .bool }]

set_option maxRecDepth 8000 in
def nodes : List NodeKind :=
[
  { tag := "text", fields := [str "s", enum "style" "Style" "body"],
    render := [
      .l "LNBuildText(box, n);"] },
  { tag := "col", fields := [kids],
    render := [
      .l "LNBuildColumn(box);"] },
  { tag := "row", fields := [kids],
    render := [
      .l "LNBuildRow(box, 44);"] },
  { tag := "button", fields := [str "label", enum "role" "Role" "plain", bool "enabled" true],
    render := [
      .l "if ([box.mode isEqualToString:@\"cell\"]) LNPin(LNRowButton(n, path), box, UIEdgeInsetsZero);",
      .l "else LNPinLeading(LNButton(n, path, box.mode), box);"] },
  { tag := "field", fields := [str "placeholder", str "value", bool "submits"],
    render := [
      .l "LNBuildInput(box, @\"plain\", @\"\", n[@\"placeholder\"], n[@\"value\"], [n[@\"submits\"] boolValue]);",
      b "box.update = ^BOOL(LNBox *b, NSDictionary *m) {" [
          .l "return LNUpdateInput(b, @\"plain\", @\"plain\", @\"\", m[@\"placeholder\"], m[@\"value\"], [m[@\"submits\"] boolValue]);"] "};"] },
  { tag := "toggle", fields := [str "label", bool "on"],
    render := [
      .l "UIStackView *s = LNStack(UILayoutConstraintAxisHorizontal, 12);",
      .l "UILabel *l = LNLabel(n[@\"label\"], @\"body\");",
      .l "UISwitch *sw = [UISwitch new];",
      .l "sw.on = [n[@\"on\"] boolValue];",
      .l "[sw addAction:[UIAction actionWithHandler:^(UIAction *a) { LNSend(path, LNEventToggle(sw.on)); }]",
      .l "forControlEvents:UIControlEventValueChanged];",
      .l "[s addArrangedSubview:l];",
      .l "[s addArrangedSubview:sw];",
      .l "LNPin(s, box, UIEdgeInsetsZero);",
      b "box.update = ^BOOL(LNBox *b, NSDictionary *m) {" [
          .l "LNSetText(l, m[@\"label\"]);",
          .l "if (sw.on != [m[@\"on\"] boolValue]) [sw setOn:[m[@\"on\"] boolValue] animated:YES];",
          .l "return YES;"] "};"] },
  { tag := "divider", fields := [],
    render := [
      .l "UIView *line = [UIView new];",
      .l "line.backgroundColor = UIColor.separatorColor;",
      .l "[line.heightAnchor constraintEqualToConstant:1 / UIScreen.mainScreen.scale].active = YES;",
      .l "LNPin(line, box, UIEdgeInsetsZero);"] },
  { tag := "spacer", fields := [], overlay := true,
    render := [
      .l "[box setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];",
      .l "[box setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];",
      .l "[box setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisHorizontal];",
      .l "[box setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisVertical];"] },
  { tag := "input", fields := [enum "kind" "InputKind" "plain", str "label", str "placeholder", str "value", bool "submits"],
    render := [
      .l "LNBuildInput(box, n[@\"kind\"], n[@\"label\"], n[@\"placeholder\"], n[@\"value\"], [n[@\"submits\"] boolValue]);",
      b "box.update = ^BOOL(LNBox *b, NSDictionary *m) {" [
          .l "return LNUpdateInput(b, m[@\"kind\"], b.node[@\"kind\"], m[@\"label\"], m[@\"placeholder\"], m[@\"value\"], [m[@\"submits\"] boolValue]);"] "};"] },
  { tag := "list", fields := [kids],
    render := [
      .l "LNBuildList(box);"] },
  { tag := "section", fields := [str "header", str "footer", kids],
    render := [
      .l "UIStackView *s = LNStack(UILayoutConstraintAxisVertical, 12);",
      .l "UILabel *header = LNLabel(n[@\"header\"], @\"body\");",
      .l "header.font = LNFont(UIFontTextStyleSubheadline, YES);",
      .l "header.textColor = UIColor.secondaryLabelColor;",
      .l "UIStackView *kids = LNStack(UILayoutConstraintAxisVertical, 12);",
      .l "UILabel *footer = LNLabel(n[@\"footer\"], @\"caption\");",
      .l "[s addArrangedSubview:header];",
      .l "[s addArrangedSubview:kids];",
      .l "[s addArrangedSubview:footer];",
      .l "LNPin(s, box, UIEdgeInsetsZero);",
      b "box.update = ^BOOL(LNBox *b, NSDictionary *m) {" [
          .l "header.text = m[@\"header\"];",
          .l "header.hidden = [m[@\"header\"] length] == 0;",
          .l "LNSetText(footer, m[@\"footer\"]);",
          .l "footer.hidden = [m[@\"footer\"] length] == 0;",
          .l "LNReconcile(kids, m[@\"c\"], LNChildPaths(b.path, [m[@\"c\"] count]), LNInner(b));",
          .l "return YES;"] "};"] },
  { tag := "labeled", fields := [str "label", str "value"],
    render := [
      .l "UIStackView *s = LNStack(UILayoutConstraintAxisHorizontal, 12);",
      .l "s.alignment = UIStackViewAlignmentFirstBaseline;",
      .l "UILabel *l = LNLabel(n[@\"label\"], @\"body\");",
      .l "UILabel *v = LNLabel(n[@\"value\"], @\"body\");",
      .l "v.textColor = UIColor.secondaryLabelColor;",
      .l "v.textAlignment = NSTextAlignmentRight;",
      .l "LNDecorate(v, n[@\"decor\"]);",
      .l "[l setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh + 1 forAxis:UILayoutConstraintAxisHorizontal];",
      .l "[l setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];",
      .l "NSString *symbol = n[@\"decor\"][@\"symbol\"];",
      .l "if (symbol.length > 0) [s addArrangedSubview:LNSymbol(symbol, @{}, UIFontTextStyleBody)];",
      .l "[s addArrangedSubview:l];",
      .l "[s addArrangedSubview:v];",
      .l "LNPin(s, box, UIEdgeInsetsZero);"] },
  { tag := "screen", fields := [str "title", bool "back", bool "refreshable", bool "largeTitle" true, int "depth", kids],
    render := [
      .l "LNBuildColumn(box);"] },
  { tag := "toolbar", fields := [enum "placement" "Placement" "trailing", kids],
    render := [
      .l "LNBuildRow(box, 0);"] },
  { tag := "tabs", fields := [strs "labels", strs "icons", int "selected", kids],
    render := [
      .l "LNBuildColumn(box);"] },
  { tag := "sheet", fields := [str "title", bool "dismissable", bool "largeTitle", enum "size" "SheetSize" "large", kids], overlay := true,
    render := [
      .l "LNBuildSheet(box);"] },
  { tag := "alert", fields := [str "title", str "message", enum "style" "AlertStyle" "alert", kids], overlay := true,
    render := [
      .l "LNBuildAlert(box);"] },
  { tag := "picker", fields := [str "label", strs "options", int "selected"],
    render := [
      .l "UIStackView *s = LNStack(UILayoutConstraintAxisHorizontal, 12);",
      .l "UILabel *l = LNLabel(n[@\"label\"], @\"body\");",
      .l "NSArray *options = n[@\"options\"];",
      .l "NSInteger selected = [n[@\"selected\"] integerValue];",
      .l "NSMutableArray *actions = [NSMutableArray array];",
      b "for (NSUInteger i = 0; i < options.count; i++) {" [
          b "UIAction *a = [UIAction actionWithTitle:options[i] image:nil identifier:nil handler:^(UIAction *x) {" [
              .l "if ((NSInteger)i != selected) LNSend(path, LNEventSelect(i));"] "}];",
          .l "a.state = (NSInteger)i == selected ? UIMenuElementStateOn : UIMenuElementStateOff;",
          .l "[actions addObject:a];"],
      .l "UIButtonConfiguration *c = UIButtonConfiguration.plainButtonConfiguration;",
      .l "c.title = selected >= 0 && selected < (NSInteger)options.count ? options[selected] : @\"\";",
      .l "c.image = [UIImage systemImageNamed:@\"chevron.up.chevron.down\"];",
      .l "c.imagePlacement = NSDirectionalRectEdgeTrailing;",
      .l "c.imagePadding = 4;",
      .l "c.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote];",
      .l "c.baseForegroundColor = UIColor.secondaryLabelColor;",
      .l "c.contentInsets = NSDirectionalEdgeInsetsZero;",
      .l "UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];",
      .l "b.menu = [UIMenu menuWithChildren:actions];",
      .l "b.showsMenuAsPrimaryAction = YES;",
      .l "[b setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];",
      .l "[s addArrangedSubview:l];",
      .l "[s addArrangedSubview:LNFiller()];",
      .l "[s addArrangedSubview:b];",
      .l "LNPin(s, box, UIEdgeInsetsZero);"] },
  { tag := "progress", fields := [str "label"],
    render := [
      .l "UIStackView *s = LNStack(UILayoutConstraintAxisVertical, 8);",
      .l "s.alignment = UIStackViewAlignmentCenter;",
      .l "UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithFrame:CGRectZero];",
      .l "[spinner startAnimating];",
      .l "[s addArrangedSubview:spinner];",
      b "if ([n[@\"label\"] length] > 0) {" [
          .l "UILabel *l = LNLabel(n[@\"label\"], @\"body\");",
          .l "l.textColor = UIColor.secondaryLabelColor;",
          .l "l.numberOfLines = 1;",
          .l "[l setContentCompressionResistancePriority:UILayoutPriorityRequired - 1 forAxis:UILayoutConstraintAxisHorizontal];",
          .l "[s addArrangedSubview:l];"],
      .l "LNPinLeading(s, box);"] },
  { tag := "icon", fields := [str "name"],
    render := [
      .l "UIImageView *v = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:n[@\"name\"]]];",
      .l "v.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody];",
      .l "v.tintColor = LNToneColor(n[@\"decor\"][@\"tone\"]) ?: UIColor.labelColor;",
      .l "v.contentMode = UIViewContentModeCenter;",
      .l "LNPinLeading(v, box);"] },
  { tag := "qr", fields := [str "text"],
    render := [
      .l "UIImage *image = ELQRImage(n[@\"text\"]);",
      .blk [("if (image) {", [
            .l "UIImageView *v = [[UIImageView alloc] initWithImage:image];",
            .l "v.layer.magnificationFilter = kCAFilterNearest;",
            .l "v.contentMode = UIViewContentModeScaleAspectFit;",
            .l "v.isAccessibilityElement = YES;",
            .l "v.accessibilityLabel = @\"QR code\";",
            .l "[NSLayoutConstraint activateConstraints:@[",
            .l "    [v.widthAnchor constraintEqualToConstant:240], [v.heightAnchor constraintEqualToAnchor:v.widthAnchor]]];",
            .l "// centred in its row, as a QR code is shown to be scanned",
            .l "v.translatesAutoresizingMaskIntoConstraints = NO;",
            .l "[box addSubview:v];",
            .l "[NSLayoutConstraint activateConstraints:@[[v.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],",
            .l "    [v.topAnchor constraintEqualToAnchor:box.topAnchor constant:8], [v.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8]]];"]), ("} else {", [
            .l "LNPin(LNLabel(n[@\"text\"], @\"body\"), box, UIEdgeInsetsZero);"])] "}"] },
  { tag := "share", fields := [str "label", str "text", bool "file"],
    render := [
      .l "// a share button looks like the app's other buttons where it is, with the system's share symbol",
      .l "NSMutableDictionary *decor = [n[@\"decor\"] mutableCopy];",
      .l "if ([decor[@\"symbol\"] length] == 0) decor[@\"symbol\"] = @\"square.and.arrow.up\";",
      .l "BOOL row = [box.mode isEqualToString:@\"cell\"];",
      .l "UIButtonConfiguration *c = LNButtonStyle(@\"plain\", decor, row ? @\"\" : box.mode);",
      .l "if (row) { c.contentInsets = NSDirectionalEdgeInsetsZero; c.imagePadding = 12; }",
      .l "c.title = n[@\"label\"];",
      .l "BOOL file = [n[@\"file\"] boolValue];",
      .l "NSString *text = n[@\"text\"];",
      .l "__block UIButton *b = nil;",
      b "b = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) {" [
          .l "id item = file ? [NSURL fileURLWithPath:text] : text;",
          .l "UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[item] applicationActivities:nil];",
          .l "share.popoverPresentationController.sourceView = b;",
          .l "[LNTop(LNController(b)) presentViewController:share animated:YES completion:nil];"] "}]];",
      .l "if (row) { b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading; LNPin(b, box, UIEdgeInsetsZero); }",
      .l "else LNPinLeading(b, box);"] },
  { tag := "link", fields := [str "label", str "url"],
    render := [
      .l "NSURL *url = [NSURL URLWithString:n[@\"url\"]];",
      .blk [("if (url) {", [
            .l "UIButtonConfiguration *c = UIButtonConfiguration.plainButtonConfiguration;",
            .l "c.title = n[@\"label\"];",
            .l "c.contentInsets = NSDirectionalEdgeInsetsZero;",
            b "UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) {" [
                .l "[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];"] "}]];",
            .l "LNPinLeading(b, box);"]), ("} else {", [
            .l "LNPin(LNLabel(n[@\"label\"], @\"body\"), box, UIEdgeInsetsZero);"])] "}"] },
  { tag := "page", fields := [str "path"],
    render := [
      .l "WKWebView *web = LNPageView(n[@\"path\"], box);",
      .l "LNPin(web, box, UIEdgeInsetsZero);",
      .l "// a page takes the rest of its screen or sheet: as tall as the space allows, the weakest wish there is",
      .l "NSLayoutConstraint *fill = [box.heightAnchor constraintEqualToConstant:100000];",
      .l "fill.priority = 1;",
      .l "fill.active = YES;"] },
  { tag := "empty", fields := [str "title", str "icon", str "message", kids],
    render := [
      .l "// the system's empty state (symbol, title, message), the actions under it",
      .l "UIStackView *s = LNStack(UILayoutConstraintAxisVertical, 0);",
      .l "UIContentUnavailableView *empty = [[UIContentUnavailableView alloc] initWithConfiguration:UIContentUnavailableConfiguration.emptyConfiguration];",
      .l "UIStackView *actions = LNStack(UILayoutConstraintAxisVertical, 12);",
      .l "actions.alignment = UIStackViewAlignmentCenter;",
      .l "[s addArrangedSubview:empty];",
      .l "[s addArrangedSubview:actions];",
      .l "LNPin(s, box, UIEdgeInsetsMake(0, 0, 24, 0));",
      b "box.update = ^BOOL(LNBox *b, NSDictionary *m) {" [
          .l "UIContentUnavailableConfiguration *c = UIContentUnavailableConfiguration.emptyConfiguration;",
          .l "c.image = [UIImage systemImageNamed:m[@\"icon\"]];",
          .l "c.text = m[@\"title\"];",
          .l "c.secondaryText = m[@\"message\"];",
          .l "empty.configuration = c;",
          .l "LNReconcile(actions, m[@\"c\"], LNChildPaths(b.path, [m[@\"c\"] count]), LNInner(b));",
          .l "return YES;"] "};"] },
  { tag := "disclosure", fields := [str "title", bool "expanded", kids],
    render := [
      .l "UIStackView *s = LNStack(UILayoutConstraintAxisVertical, 12);",
      .l "UIButtonConfiguration *c = UIButtonConfiguration.plainButtonConfiguration;",
      .l "c.imagePlacement = NSDirectionalRectEdgeTrailing;",
      .l "c.contentInsets = NSDirectionalEdgeInsetsZero;",
      .l "c.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote];",
      .l "UIButton *header = [UIButton buttonWithConfiguration:c primaryAction:nil];",
      .l "header.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;",
      .l "__weak LNBox *weakBox = box;",
      b "[header addAction:[UIAction actionWithHandler:^(UIAction *a) {" [
          .l "LNSend(path, LNEventToggle(![weakBox.node[@\"expanded\"] boolValue]));"] "}] forControlEvents:UIControlEventTouchUpInside];",
      .l "UIStackView *kids = LNStack(UILayoutConstraintAxisVertical, 12);",
      .l "[s addArrangedSubview:header];",
      .l "[s addArrangedSubview:kids];",
      .l "LNPin(s, box, UIEdgeInsetsZero);",
      b "box.update = ^BOOL(LNBox *b, NSDictionary *m) {" [
          .l "UIButtonConfiguration *hc = header.configuration;",
          .l "hc.title = m[@\"title\"];",
          .l "hc.image = [UIImage systemImageNamed:[m[@\"expanded\"] boolValue] ? @\"chevron.down\" : @\"chevron.forward\"];",
          .l "header.configuration = hc;",
          .l "kids.hidden = ![m[@\"expanded\"] boolValue];",
          .l "LNReconcile(kids, m[@\"c\"], LNChildPaths(b.path, [m[@\"c\"] count]), LNInner(b));",
          .l "return YES;"] "};"] },
  { tag := "stepper", fields := [str "label", int "value", int "lo", int "hi", str "detail"],
    render := [
      .l "UIStackView *s = LNStack(UILayoutConstraintAxisHorizontal, 12);",
      .l "UILabel *l = LNLabel(@\"\", @\"body\");",
      .l "UILabel *detail = LNLabel(@\"\", @\"body\");",
      .l "detail.textColor = UIColor.secondaryLabelColor;",
      .l "detail.textAlignment = NSTextAlignmentRight;",
      .l "UIStepper *stepper = [UIStepper new];",
      .l "[stepper addAction:[UIAction actionWithHandler:^(UIAction *a) { LNSend(path, LNEventSelect((NSInteger)stepper.value)); }]",
      .l "  forControlEvents:UIControlEventValueChanged];",
      .l "[stepper setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];",
      .l "[s addArrangedSubview:l];",
      .l "[s addArrangedSubview:detail];",
      .l "[s addArrangedSubview:stepper];",
      .l "LNPin(s, box, UIEdgeInsetsZero);",
      b "box.update = ^BOOL(LNBox *b, NSDictionary *m) {" [
          .l "NSInteger value = [m[@\"value\"] integerValue], lo = [m[@\"lo\"] integerValue], hi = MAX(lo, [m[@\"hi\"] integerValue]);",
          .l "NSString *d = m[@\"detail\"];",
          .l "l.text = d.length == 0 ? [NSString stringWithFormat:@\"%@: %ld\", m[@\"label\"], (long)value] : m[@\"label\"];",
          .l "detail.text = d;",
          .l "detail.hidden = d.length == 0;",
          .l "stepper.minimumValue = lo;",
          .l "stepper.maximumValue = hi;",
          .l "stepper.value = value;",
          .l "return YES;"] "};"] } ]

/-- The arm for a tag the shell does not know (`LNDecode` turns it into `{"t":"unknown","name":t}`). -/
def unknownArm : List Stmt := [
    .l "UILabel *l = LNLabel([NSString stringWithFormat:@\"Unsupported node: %@\", n[@\"name\"]], @\"caption\");",
    .l "LNPin(l, box, UIEdgeInsetsZero);"]

/-! The string enums, from the Lean types (`LeanNativeShell.Check` proves the lists complete). -/

def allStyles : List TextStyle :=
  [.title, .body, .caption, .largeTitle, .title3, .headline, .subheadline, .callout, .footnote, .caption2]
def allPlacements : List Placement := [.trailing, .leading, .cancel, .confirm, .bottom]
def allAlertStyles : List AlertStyle := [.alert, .actionSheet]
def allSheetSizes : List SheetSize := [.large, .medium]
def allTones : List Tone := [.standard, .secondary, .tint, .positive, .negative, .warning]
def allRoles : List ButtonRole := [.plain, .primary, .destructive, .secondary, .cancel]
def allInputKinds : List InputKind := [.plain, .secure, .multiline, .number, .decimal]

/-- (name, values) of each string enum a node field takes. -/
def stringEnums : List (String × List String) :=
  [ ("Role", allRoles.map (·.str)), ("Style", allStyles.map (·.str)), ("InputKind", allInputKinds.map (·.str)),
    ("Tone", allTones.map (·.str)), ("Placement", allPlacements.map (·.str)),
    ("AlertStyle", allAlertStyles.map (·.str)), ("SheetSize", allSheetSizes.map (·.str)) ]

/-! The events (PROTOCOL.md, "Client → CLI"): name, and the Objective-C parameter and its JSON value if the
event carries a `value`. -/

def events : List (String × Option (String × String)) :=
  [ ("click", none), ("submit", none), ("dismiss", none), ("input", some ("NSString *value", "value")),
    ("toggle", some ("BOOL value", "@(value)")), ("select", some ("NSInteger value", "@(value)")) ]

/-- `LNEventInput` for `input`. -/
def eventFn (name : String) : String := "LNEvent" ++ name.capitalize

def eventSig (e : String × Option (String × String)) : String :=
  s!"NSDictionary *{eventFn e.1}({(e.2.map (·.1)).getD "void"})"

end LeanNativeShell
