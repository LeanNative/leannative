import ElmLean.Wire

namespace ElmLean

/-- Erase handlers: this is exactly what the CLI serializes in its replies. -/
def Html.toWire {msg : Type} : Html msg → Wire
  | .text s st => .text s st
  | .col cs => .col (cs.map toWire)
  | .row cs => .row (cs.map toWire)
  | .button l r c => .button l r c.isSome
  | .field p v _ s => .field p v s.isSome
  | .toggle l on _ => .toggle l on
  | .divider => .divider
  | .spacer => .spacer

end ElmLean
