#!/usr/bin/env python3
"""Copy a macOS static archive (one architecture, arm64 or x86_64), retargeting every Mach-O member's
LC_BUILD_VERSION in place: platform 2 = iOS, 7 = iOS Simulator, 6 = Mac Catalyst; minos and sdk both set to
<minos> (for Catalyst the iOS deployment target, as clang writes for -target <arch>-apple-ios17.0-macabi).
usage: retarget_ar.py <platform-number> <minos> in.a out.a"""
import struct, sys
plat = int(sys.argv[1]); major, minor = (int(x) for x in sys.argv[2].split('.'))
minos = (major << 16) | (minor << 8)
b = bytearray(open(sys.argv[3], 'rb').read())
assert b[:8] == b'!<arch>\n'
off, n, patched = 8, 0, 0
while off < len(b):
    hdr = b[off:off + 60]
    name = hdr[:16].decode().strip()
    size = int(hdr[48:58].decode().strip())
    data = off + 60
    if name.startswith('#1/'):
        nl = int(name[3:])
        name = b[data:data + nl].rstrip(b'\0').decode()
        body = data + nl
    else:
        body = data
    end = data + size
    if struct.unpack_from('<I', b, body)[0] == 0xfeedfacf:
        ncmds = struct.unpack_from('<I', b, body + 16)[0]
        lc = body + 32
        for _ in range(ncmds):
            cmd, csize = struct.unpack_from('<II', b, lc)
            if cmd == 0x32:
                struct.pack_into('<III', b, lc + 8, plat, minos, minos)
                patched += 1
            elif cmd == 0x24:
                raise SystemExit(f"{name}: LC_VERSION_MIN_MACOSX")
            lc += csize
    n += 1
    off = end + (end & 1)
open(sys.argv[4], 'wb').write(b)
print(f"{sys.argv[4]}: {n} members, {patched} retargeted")
