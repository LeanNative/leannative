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
  | .input k l p v _ s => .input k l p v s.isSome
  | .list cs => .list (cs.map toWire)
  | .section h f cs => .section h f (cs.map toWire)
  | .labeled l v => .labeled l v
  | .screen t b cs r => .screen t b.isSome (cs.map toWire) r.isSome
  | .toolbar cs => .toolbar (cs.map toWire)
  | .tabs ls is sel _ cs => .tabs ls is sel (cs.map toWire)
  | .sheet t d cs => .sheet t d.isSome (cs.map toWire)
  | .alert t m cs => .alert t m (cs.map toWire)
  | .picker l os sel _ => .picker l os sel
  | .progress l => .progress l
  | .icon n => .icon n
  | .qr t => .qr t
  | .share l t f => .share l t f
  | .link l u => .link l u
  | .page p => .page p
  | .empty t i m cs => .empty t i m (cs.map toWire)
  | .disclosure t e _ cs => .disclosure t e (cs.map toWire)
  | .stepper l v lo hi _ d => .stepper l v lo hi d

end ElmLean
