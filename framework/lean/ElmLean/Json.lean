import Lean.Data.Json
import ElmLean.Program

/-! TRUSTED SHELL: JSON codecs. Nothing here is proven; `framework/scripts/protocol_test.py`
exercises it against the theorems' statements. -/

namespace ElmLean
open Lean

def TextStyle.str : TextStyle → String
  | .title => "title"
  | .body => "body"
  | .caption => "caption"

def ButtonRole.str : ButtonRole → String
  | .plain => "plain"
  | .primary => "primary"
  | .destructive => "destructive"

def Wire.toJson : Wire → Json
  | .text s st => Json.mkObj [("t", Json.str "text"), ("s", Json.str s), ("style", Json.str st.str)]
  | .col cs => Json.mkObj [("t", Json.str "col"), ("c", Json.arr (cs.map Wire.toJson).toArray)]
  | .row cs => Json.mkObj [("t", Json.str "row"), ("c", Json.arr (cs.map Wire.toJson).toArray)]
  | .button l r en =>
    Json.mkObj [("t", Json.str "button"), ("label", Json.str l), ("role", Json.str r.str), ("enabled", Json.bool en)]
  | .field p v s =>
    Json.mkObj [("t", Json.str "field"), ("placeholder", Json.str p), ("value", Json.str v), ("submits", Json.bool s)]
  | .toggle l on => Json.mkObj [("t", Json.str "toggle"), ("label", Json.str l), ("on", Json.bool on)]
  | .divider => Json.mkObj [("t", Json.str "divider")]
  | .spacer => Json.mkObj [("t", Json.str "spacer")]

instance : ToJson Wire := ⟨Wire.toJson⟩

def Event.fromJson? (j : Json) : Except String Event := do
  let k ← j.getObjVal? "k" >>= Json.getStr?
  match k with
  | "click" => pure .click
  | "submit" => pure .submit
  | "input" => return .input (← j.getObjVal? "value" >>= Json.getStr?)
  | "toggle" => return .toggle (← j.getObjVal? "value" >>= Json.getBool?)
  | other => throw s!"unknown event kind '{other}'"

/-- PROTOCOL.md: `seq` and every path element must be a JSON number whose VALUE is a
non-negative integer, whatever the spelling (`1`, `1.0`, `1e0`, `10e-1` all denote 1; `1.5`,
`-1`, `"1"`, `true`, `null` do not). Lean parses a number into `⟨mantissa, exponent⟩` with
value `mantissa / 10^exponent`, so the value is a natural number iff `mantissa ≥ 0` and
`10^exponent` divides `mantissa`, and then it is `mantissa / 10^exponent`. (`Json.getNat?`
would accept `1e0` but reject `1.0` and `10e-1`, because the parser normalises only the former.)

Cost: `10^exponent` can only divide a positive `mantissa` if `2^exponent ≤ mantissa`, so an
exponent above `Nat.log2 mantissa` is rejected without computing anything (`1e-99999999`);
otherwise `10^exponent` has at most about 3.4 times the mantissa's bits and the decision is one
`Nat.log2`, one `Nat.pow` and one division with remainder, each a single GMP call, so a mantissa
with `10^6` trailing zeros (`1`, a million zeros, `e-1000000`) is decided in a few milliseconds.
(The bit length is used rather than the decimal length because `toString` on a big `Nat` is a
digit-by-digit division loop in Lean itself, 2 s for `10^5` digits; the first version of this
function stripped the zeros one by one in the same way and was quadratic in their number.) What
this function cannot help is Lean's stdlib `Json.parse`, which runs before it. It materialises
`10^N` for a literal like `1eN` (`1E400` arrives as the mantissa `10^400`; an exponent of `10^18`
panics the process in `Nat.pow` before any reply is written), a trusted-shell limitation.

It also accumulates every mantissa digit by digit (`10 * acc + d`), quadratic in the digit count:
about 0.25 s for `10^5` digits and 25 to 30 s for `10^6`, paid by a plain integer literal of that
length as well, wherever one reaches the CLI. -/
def Json.getNatValue? : Json → Except String Nat
  | .num ⟨m, e⟩ =>
    if m < 0 then throw "natural number expected"
    else if m == 0 then pure 0
    else
      let n := m.toNat
      -- `10^e ∣ n` with `n ≥ 1` needs `2^e ≤ 10^e ≤ n`, i.e. `e ≤ n.log2`
      if e > n.log2 then throw "natural number expected"
      else
        let p := 10 ^ e
        if n % p == 0 then pure (n / p) else throw "natural number expected"
  | _ => throw "natural number expected"

def Request.ofJson? (j : Json) : Except String Request := do
  let seq ← j.getObjVal? "seq" >>= Json.getNatValue?
  let pathArr ← j.getObjVal? "path" >>= Json.getArr?
  let path ← pathArr.toList.mapM Json.getNatValue?
  let event ← j.getObjVal? "event" >>= Event.fromJson?
  pure ⟨seq, path, event⟩

def ErrorCode.str : ErrorCode → String
  | .stale => "stale"
  | .badPath => "bad-path"
  | .noHandler => "no-handler"
  | .badJson _ => "bad-json"

def Reply.toJson : Reply → Json
  | .view seq w => Json.mkObj [("seq", Lean.toJson seq), ("view", w.toJson)]
  | .error seq code cur =>
    let base := [("seq", Lean.toJson seq), ("error", Json.str code.str)]
    let detail := match code with
      | .badJson d => [("detail", Json.str d)]
      | _ => []
    let view := match cur with
      | some w => [("view", w.toJson)]
      | none => []
    Json.mkObj (base ++ detail ++ view)

end ElmLean
