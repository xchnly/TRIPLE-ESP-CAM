#!/usr/bin/env bash
# Uji di PC: parser pesan firmware (mesh.h) harus cocok dengan format aplikasi Flutter.
# Butuh: g++, Flutter/Dart. Jalankan dari folder repo:  bash firmware/test/run_parser_test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ROOT/firmware/esp32cam/mesh.h" "$ROOT/firmware/test/parser_main.inc" "$TMP/t.cpp" <<'PY'
import sys
src = open(sys.argv[1]).read()
def grab(sig):
    i = src.index(sig)
    return src[i:src.index('\n}\n', i) + 2]
code = '#include <cstdio>\n#include <cstring>\n#include <cstdint>\n#include <string>\n#include <iostream>\n#define MESH_MAX_MSG 1400\n'
code += '\n'.join(grab(f) for f in ['static uint32_t fnv1a', 'static bool parseHeader', 'static size_t withTtl'])
code += '\n' + open(sys.argv[2]).read()
open(sys.argv[3], 'w').write(code)
PY
g++ -std=c++17 -Wall -o "$TMP/t" "$TMP/t.cpp"

cd "$ROOT/mobile"
dart run tool/sample_wires.dart > "$TMP/in.txt"
sed -n 2p "$TMP/in.txt" | sed 's/"ttl":15/"ttl":10/' >> "$TMP/in.txt"   # TTL 2 digit -> 1 digit
"$TMP/t" < "$TMP/in.txt" > "$TMP/out.txt"
dart run tool/verify_wires.dart "$TMP/out.txt" | tee "$TMP/res.txt"
! grep -q "FAIL\|ok=false" "$TMP/res.txt" && echo "OK: firmware & aplikasi cocok"
