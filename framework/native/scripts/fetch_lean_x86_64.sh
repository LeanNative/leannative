#!/bin/bash
# Fetch Lean's official macOS x86_64 release and keep only the static libraries a native app links, for the
# x86_64 (Intel) slice of a Mac Catalyst build. Lean installs only the host's architecture (arm64 here), and
# Catalyst apps are universal. Nothing from the download is run: it is checked against the release's
# published SHA-256, and only lib/ archives (plus include/, to compare headers) are extracted.
#
#   fetch_lean_x86_64.sh <dest dir> [version]      (version defaults to 4.35.0, the framework's toolchain)
#
# Then: export LEAN_X86_64_PREFIX=<dest dir>/lean-<version>-darwin  (ios_lean_sources.sh … maccatalyst reads it)
set -euo pipefail
DEST="${1:?destination directory}"; VERSION="${2:-4.35.0}"
# the darwin (x86_64) asset of each release, with the digest GitHub publishes for it
case "$VERSION" in
  4.35.0) SHA256=0b43be5c7ecfb36016566a41005ab62bdb04743e6bfd5837e45f796ef4750b4e ;;
  *) echo "no pinned checksum for $VERSION: add the darwin asset's sha256 from" \
          "https://github.com/leanprover/lean4/releases/tag/v$VERSION" >&2; exit 2 ;;
esac
NAME="lean-$VERSION-darwin"
URL="https://github.com/leanprover/lean4/releases/download/v$VERSION/$NAME.tar.zst"
command -v zstd >/dev/null || { echo "needs zstd (brew install zstd)" >&2; exit 2; }
mkdir -p "$DEST"
ARCHIVE="$DEST/$NAME.tar.zst"
if [ ! -f "$ARCHIVE" ] || [ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" != "$SHA256" ]; then
  curl -fL --retry 3 -o "$ARCHIVE.part" "$URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
GOT="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
[ "$GOT" = "$SHA256" ] || { echo "checksum mismatch for $URL: got $GOT, want $SHA256" >&2; exit 1; }
rm -rf "${DEST:?}/$NAME"
# tar stops reading after the last requested member and zstd then gets SIGPIPE. The archive's
# checksum was verified above, so tar's exit status is the extraction result that matters.
set +o pipefail
zstd -dc "$ARCHIVE" | tar -x -C "$DEST" -f - \
  "$NAME/lib/lean/libLean.a" "$NAME/lib/lean/libStd.a" "$NAME/lib/lean/libInit.a" "$NAME/lib/lean/libleanrt.a" \
  "$NAME/lib/libuv.a" "$NAME/lib/libgmp.a" "$NAME/include"
set -o pipefail
for l in lean/libLean.a lean/libStd.a lean/libInit.a lean/libleanrt.a libuv.a libgmp.a; do
  lipo -info "$DEST/$NAME/lib/$l" | grep -q 'architecture: x86_64' || { echo "$l is not x86_64" >&2; exit 1; }
done
echo "$URL"
echo "sha256 $GOT"
echo "export LEAN_X86_64_PREFIX=\"$DEST/$NAME\""
