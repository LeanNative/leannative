#!/bin/bash
# Scaffold a new ElmLean app from framework/template:
#
#   framework/scripts/new_app.sh <Name> <directory>        e.g.  new_app.sh Notes apps/notes
#
# <Name> is the Lean namespace and module (UpperCamelCase); the Swift names are <Name>App, <Name>Screen
# and <Name>Gen, the executable is <name>-cli. The directory must not exist; the app requires the
# framework by a relative path, so it can live anywhere on this disk. Then:
#   cd <directory> && make gen && make check
set -euo pipefail
if [ $# -ne 2 ]; then
  echo "usage: $0 <Name> <directory>" >&2
  exit 2
fi
NAME="$1"
DIR="$2"
[[ "$NAME" =~ ^[A-Z][A-Za-z0-9]*$ ]] || { echo "new_app: <Name> must be UpperCamelCase letters and digits, got '$NAME'" >&2; exit 2; }
case "$NAME" in
  App|Html|Store|Model|Msg|Event|Wire|Session|ElmLean|ElmGen|Lean|Init|Std|Lake)
    echo "new_app: '$NAME' collides with a framework, Lean or Swift runtime name; pick another" >&2; exit 2 ;;
esac
[ ! -e "$DIR" ] || { echo "new_app: $DIR already exists" >&2; exit 2; }
FW_ABS="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$DIR"
DIR_ABS="$(cd "$DIR" && pwd)"
LOWER="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')"
FW_REL="$(/opt/homebrew/bin/python3 -I -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$FW_ABS" "$DIR_ABS")"
case "$FW_REL" in *" "*) echo "new_app: the path from $DIR to the framework contains a space ($FW_REL); make cannot quote it" >&2; rmdir "$DIR_ABS"; exit 2 ;; esac

( cd "$FW_ABS/template" && find . -type f ) | while IFS= read -r f; do
  rel="${f#./}"
  out="$DIR_ABS/${rel//__Name__/$NAME}"
  mkdir -p "$(dirname "$out")"
  sed -e "s#__Name__#$NAME#g" -e "s#__name__#$LOWER#g" -e "s#__FW__#$FW_REL#g" "$FW_ABS/template/$rel" > "$out"
done
cp "$FW_ABS/lean/lean-toolchain" "$DIR_ABS/lean-toolchain"
mkdir -p "$DIR_ABS/generated"
echo "new_app: created $DIR ($NAME, framework at $FW_REL). Next:"
echo "  cd $DIR && make gen && make check     # generate the Swift app, then run every gate"
echo "  make ios                               # the generated native app in the iPhone simulator"
