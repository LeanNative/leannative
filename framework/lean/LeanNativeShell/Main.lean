import LeanNativeShell.Header
import LeanNativeShell.App
import LeanNativeShell.Store
import LeanNativeShell.Node
import LeanNativeShell.Render
import LeanNativeShell.Capabilities
import LeanNativeShell.Check

/-! `leannative-shell <dir>`: writes the native shell's Objective-C into `<dir>` (a build directory: the files are
outputs, never sources). A file whose text is unchanged is left alone, so Xcode does not recompile it. -/

open LeanNativeShell

def header (name : String) : List String := shellHeader name

def files : List (String × List Stmt) :=
  [ ("LeanNativeShell.h", headerFile), ("LNApp.m", appFile), ("LNStore.m", storeFile), ("LNNode.m", nodeFile),
    ("LNRender.m", renderFile), ("LNCapabilities.m", capsFile) ]

def main (args : List String) : IO UInt32 := do
  let [dir] := args | IO.eprintln "usage: leannative-shell <output dir>"; return 2
  unless Check.problems.isEmpty do
    for p in Check.problems do IO.eprintln s!"leannative-shell: {p}"
    return 1
  IO.FS.createDirAll dir
  for (name, body) in files do
    let path := System.FilePath.mk dir / name
    let text := LeanNativeShell.file (header name) body
    let old ← (try IO.FS.readFile path catch _ => pure "")
    if old != text then IO.FS.writeFile path text
  -- a file from an older shell (a Swift one, say) must not linger in the build
  for entry in (← System.FilePath.readDir dir) do
    let shell := [".swift", ".m", ".h"].any fun (ext : String) => entry.fileName.endsWith ext
    if shell && !(files.any (·.1 == entry.fileName)) then
      IO.FS.removeFile entry.path
  return 0
