import ElmShell.Grammar

/-! # ElmShell.Node: `ELNode.m`, decoding a node and `ELIsOverlay`, printed from the grammar table -/

namespace ElmShell

set_option maxRecDepth 8000 in
def nodeHelpers : List Stmt := [
    .pp "#import \"ElmLeanShell.h\"",
    .blank,
    b "static NSString *ELS(NSDictionary *o, NSString *k) {" [
        .l "return [o[k] isKindOfClass:NSString.class] ? o[k] : @\"\";"],
    .blank,
    b "static NSNumber *ELB(NSDictionary *o, NSString *k, BOOL dflt) {" [
        .l "return [o[k] isKindOfClass:NSNumber.class] ? @([o[k] boolValue]) : @(dflt);"],
    .blank,
    b "static NSNumber *ELN(NSDictionary *o, NSString *k) {" [
        .l "return [o[k] isKindOfClass:NSNumber.class] ? @([o[k] integerValue]) : @0;"],
    .blank,
    b "static NSArray *ELSS(NSDictionary *o, NSString *k) {" [
        .l "NSMutableArray *out = [NSMutableArray array];",
        .l "if ([o[k] isKindOfClass:NSArray.class])",
        .l "    for (id x in o[k]) [out addObject:[x isKindOfClass:NSString.class] ? x : @\"\"];",
        .l "return out;"],
    .blank,
    b "static NSString *ELE(NSDictionary *o, NSString *k, NSArray<NSString *> *values, NSString *dflt) {" [
        .l "NSString *s = ELS(o, k);",
        .l "return [values containsObject:s] ? s : dflt;"],
    .blank,
    .l "/// `Html.identified`: the identifier any node may carry, kept when it is a non-empty string.",
    b "static NSDictionary *ELWithId(NSDictionary *o, NSDictionary *n) {" [
        .l s!"NSString *ident = ELS(o, {lit idKey});",
        .l "if (ident.length == 0) return n;",
        .l "NSMutableDictionary *m = [n mutableCopy];",
        .l s!"m[{lit idKey}] = ident;",
        .l "return m;"],
    .blank,
    b "static NSArray *ELK(NSDictionary *o) {" [
        .l "NSMutableArray *out = [NSMutableArray array];",
        .l "if ([o[@\"c\"] isKindOfClass:NSArray.class])",
        .l "    for (id x in o[@\"c\"]) [out addObject:ELDecode(x)];",
        .l "return out;"],
    .blank]

/-- The decoding of one field from the JSON object `o`. -/
def Field.decode (f : Field) : String :=
  let v := match f.ty with
    | .str => s!"ELS(o, {lit f.key})"
    | .bool d => s!"ELB(o, {lit f.key}, {if d then "YES" else "NO"})"
    | .int => s!"ELN(o, {lit f.key})"
    | .strs => s!"ELSS(o, {lit f.key})"
    | .enum name d =>
      let vs := (stringEnums.lookup name).getD []
      s!"ELE(o, {lit f.key}, @[{", ".intercalate (vs.map lit)}], {lit d})"
    | .kids => "ELK(o)"
  s!", {lit f.key}: {v}"

def decodeLine (k : NodeKind) : Stmt :=
  .l s!"if ([t isEqualToString:{lit k.tag}]) return ELWithId(o, @\{@\"t\": t{String.join (k.fields.map (·.decode))}});"

def nodeFile : List Stmt :=
  nodeHelpers ++
  [ b "NSDictionary *ELDecode(id json) {"
      ([ .l "if (![json isKindOfClass:NSDictionary.class]) return @{@\"t\": @\"unknown\", @\"name\": @\"not an object\"};",
         .l "NSDictionary *o = json;",
         .l "NSString *t = [o[@\"t\"] isKindOfClass:NSString.class] ? o[@\"t\"] : @\"?\";" ] ++
       nodes.map decodeLine ++ [ .l "return @{@\"t\": @\"unknown\", @\"name\": t};" ]),
    .blank,
    b "BOOL ELIsOverlay(NSDictionary *node) {"
      [ .l s!"return [@[{", ".intercalate ((nodes.filter (·.overlay)).map (lit ·.tag))}] containsObject:node[@\"t\"]];" ] ]

end ElmShell
