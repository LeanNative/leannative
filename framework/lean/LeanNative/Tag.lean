/-! # Tags: which constructor a value is

`Tag.tag` names a value's constructor and, when one of the constructor's fields is tagged itself, that field's
tag after a dot: `home.feeBump`, `host.renamed.some`, `host.booted.restored`. `Tag.all` is every tag a value of
the type can have. A run keeps a record of the messages and commands an app handled by their tags
(`Native.Tagging`, `LEANNATIVE_COVERAGE`), and the journeys report the ones that never came.

A tag never carries a field's value, only constructors' names: what a message holds (a key, an address, a
person) stays out of the record.

An app's message types derive it where the record is wanted, a journeys executable say, with
`LeanNative.TagDeriving` imported (`deriving instance LeanNative.Tag for HomeMsg, Msg`, the types a field holds
first). The deriving handler is compile-time code that needs `Lean`: the module that ships in the iOS app never
imports it, and this one imports nothing. -/

namespace LeanNative

class Tag (α : Type u) where
  /-- the value's constructor, and the tag of its first tagged field after a dot -/
  tag : α → String
  /-- every tag a value of the type can have -/
  all : Array String

/-- An outcome: whether it failed. -/
instance : Tag (Except ε α) where
  tag | .error _ => "error" | .ok _ => "ok"
  all := #["error", "ok"]

/-- Whether there is one (an answer's error, a result that may be missing). -/
instance : Tag (Option α) where
  tag | none => "none" | some _ => "some"
  all := #["none", "some"]

end LeanNative
