#!/usr/bin/env bash
# test_device.sh - stage-1 console blob device test (run on a bench with the
# panel reachable over telnet).
#
# Exercises the four console commands (peek / poke / fun / fur) against the
# stage-1 blob already running on the panel, through the house tool
# tools/screen_probe.py.  Every check opens its own console (the house style:
# separate invocations), and every address is derived at runtime from the
# built ELF and the sources - nothing is hardcoded.
#
#   1. peek  - read the installed blob's head at its runtime LMA (PEEK_BLOB_DST
#              in cmd.S) and compare it with the head of the built ELF's
#              .peekblob section.  Proves the running blob IS the built image
#              and that the peek command works.
#   2. poke  - write a deterministic 16-byte pattern to free RAM and let the
#              tool verify it back (peek matches what was written).
#   3. fun   - call pk_marker (the blob's UART write helper) with no arg; the
#              return value is sent and discarded by design, so expect
#              "ok (return discarded)".
#   4. fur   - call pk_marker the same way; the return value must be
#              r0 = UART2_DR (the UART2 data-register address it writes to).
#
# Note on fun/fur: pk_marker writes its argument byte to the same UART, so the
# byte lands between the chi! beacon and the reply's size field.  With no arg
# that byte is 0x00, which the house tool's reader tolerates for fun (the size
# field is all zeros: it parses as an empty-payload reply), but not for fur
# (the size field shifts).  So check 4 parses the raw bytes the house tool
# dumps in its "incomplete reply" report and verifies size/payload/crc itself.
#
# Requirements: PANEL_PORT set to the panel's telnet console, e.g.
#   PANEL_PORT=socket://rpi2.local:2000 make test
#
# Exit status: 0 when every check passes, 1 when any check fails,
# 2 when PANEL_PORT is unset.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROBE="$SCRIPT_DIR/../tools/screen_probe.py"
ELF="$SCRIPT_DIR/stage1_loader.elf"
OBJDUMP=${OBJDUMP:-arm-none-eabi-objdump}
NM=${NM:-arm-none-eabi-nm}
PY=${PY:-python3}

if [ -z "${PANEL_PORT:-}" ]; then
    echo "PANEL_PORT is not set." >&2
    echo "Point it at the panel's telnet console, e.g.:" >&2
    echo "  PANEL_PORT=socket://rpi2.local:2000 make test" >&2
    exit 2
fi

if [ ! -x "$ELF" ] && [ ! -f "$ELF" ]; then
    echo "built ELF not found: $ELF (run 'make' first)" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- derive every address at runtime --------------------------------------

# .peekblob LMA: the runtime address of the installed blob (its install
# destination is PEEK_BLOB_DST, see cmd.S).
BLOB_LMA=$($OBJDUMP -h "$ELF" | awk '$2 == ".peekblob" { print $5 }')
# pk_marker LMA inside the blob.
PK_LMA=$($NM "$ELF" | awk '$3 == "pk_marker" { print $1 }')
# The blob's runtime install address (from the source, SSOT: cmd.S).
PEEK_BLOB_DST=$(grep -m1 -E '^\s*\.equ\s+PEEK_BLOB_DST' "$SCRIPT_DIR/cmd.S" | awk '{ print $3 }')
# UART2 base (from the source, SSOT: stage1.S); DR is at base + 0x00.
UART2_BASE=$(grep -m1 -E '^\s*\.equ\s+UART2_BASE' "$SCRIPT_DIR/stage1.S" | awk '{ print $3 }')

for v in BLOB_LMA PK_LMA PEEK_BLOB_DST UART2_BASE; do
    if [ -z "${!v}" ]; then
        echo "failed to derive $v from $ELF / sources" >&2
        exit 1
    fi
done
# bash arithmetic takes bare hex; strip an optional 0x prefix.
BLOB_LMA=$((16#${BLOB_LMA#0x}))
PK_LMA=$((16#${PK_LMA#0x}))
PEEK_BLOB_DST=$((16#${PEEK_BLOB_DST#0x}))
UART2_BASE=$((16#${UART2_BASE#0x}))

PK_RT=$((PEEK_BLOB_DST + (PK_LMA - BLOB_LMA) + 1))   # +1: LMA is even, entry is odd (Thumb)
UART2_DR=$((UART2_BASE + 0x00))

# Expected blob head: the first 8 bytes of the built .peekblob
# (objdump -s data line: offset, then 32-bit hex words).
$OBJDUMP -s -j .peekblob "$ELF" | awk '$1 ~ /^[0-9a-f]+$/ && NF >= 2 { print $2 $3; exit }' | xxd -r -p > "$TMP/expected_head.bin"
[ "$(wc -c < "$TMP/expected_head.bin")" -eq 8 ] || { echo "failed to extract the 8-byte blob head" >&2; exit 1; }

# ---- the four checks -------------------------------------------------------

# The rpi2 telnet gateway intermittently swallows a fresh connection (no
# comok for minutes, then fine).  All four probes are idempotent, so each
# check retries its whole probe+assert pair up to 3 times.

check_peek() {
    "$PY" "$PROBE" peek "$PEEK_BLOB_DST" 8 -w "$TMP/live.bin" >"$TMP/peek.out" 2>&1
    cmp -s "$TMP/expected_head.bin" "$TMP/live.bin"
}

POKE_ADDR=0x650000   # free RAM above the blob; the tool verifies it back
POKE_HEX=000102030405060708090a0b0c0d0e0f

check_poke() {
    "$PY" "$PROBE" poke "$POKE_ADDR" "$POKE_HEX" --verify >"$TMP/poke.out" 2>&1
    grep -q 'verify: peek matches the written data' "$TMP/poke.out"
}

check_fun() {
    # No arg: pk_marker(0) puts a 0x00 byte on the wire between the chi! beacon
    # and the reply; the house reader then parses the reply as size=0 (empty
    # payload, crc 0) and reports success.
    printf 'fun 0x%08x\nquit\n' "$PK_RT" | "$PY" "$PROBE" shell >"$TMP/fun.out" 2>&1
    grep -q 'ok (return discarded)' "$TMP/fun.out"
}

check_fur() {
    # Same no-arg call; the reader cannot parse the shifted size field, so it
    # dumps the raw bytes in its failure message.  Parse them: find the chi!
    # beacon, try the frame at both alignments (with/without the stray arg
    # byte), require size=4, verify the CRC32, and check r0 == UART2_DR.
    printf 'fur 0x%08x\nquit\n' "$PK_RT" | "$PY" "$PROBE" shell >"$TMP/fur.out" 2>&1
    local hex
    hex=$(sed -n 's/.*incomplete reply ([0-9]* bytes: \([^)]*\)).*/\1/p' "$TMP/fur.out" | head -1)
    [ -n "$hex" ] || return 1
    "$PY" - "$hex" "$(printf '%08x' "$UART2_DR")" <<'PYEOF'
import struct, sys, zlib

b = bytes.fromhex(sys.argv[1].replace(" ", ""))
expected_dr = int(sys.argv[2], 16)
m = b.find(b"chi!")
if m < 0:
    sys.exit(1)  # no beacon: the blob never ran
body = b[m + 4:]
for skip in (0, 1):  # 0 = clean frame, 1 = pk_marker's stray arg byte in front
    t = body[skip:]
    if len(t) < 12:
        continue
    size = struct.unpack("<I", t[:4])[0]
    if size != 4:
        continue
    payload = t[4:8]
    crc = struct.unpack("<I", t[8:12])[0]
    if crc != (zlib.crc32(payload) & 0xFFFFFFFF):
        continue
    sys.exit(0 if struct.unpack("<I", payload)[0] == expected_dr else 2)
sys.exit(1)
PYEOF
}

# run NAME OUTFILE FN - run FN up to 3 times; print PASS/FAIL; dump OUTFILE
# on failure.
run() {
    local name=$1 out=$2 fn=$3 i
    for i in 1 2 3; do
        if "$fn"; then
            echo "PASS: $name"
            PASS=$((PASS + 1))
            return 0
        fi
        echo "  (attempt $i/3 failed, retrying)" >&2
        sleep 1
    done
    echo "FAIL: $name"
    sed 's/^/    /' "$out"
    FAIL=$((FAIL + 1))
    return 1
}

PASS=0
FAIL=0

echo "panel:  $PANEL_PORT"
echo "blob:   built .peekblob LMA 0x$(printf '%08x' "$BLOB_LMA") -> runtime 0x$(printf '%08x' "$PEEK_BLOB_DST")"
echo "pk_marker runtime: 0x$(printf '%08x' "$PK_RT")"
echo

run "peek: blob head at 0x$(printf '%08x' "$PEEK_BLOB_DST") matches the built ELF" \
    "$TMP/peek.out" check_peek
run "poke: 16-byte pattern to 0x$(printf '%08x' "$POKE_ADDR") verifies" \
    "$TMP/poke.out" check_poke
run "fun: pk_marker at 0x$(printf '%08x' "$PK_RT") returns (discarded)" \
    "$TMP/fun.out" check_fun
run "fur: pk_marker at 0x$(printf '%08x' "$PK_RT") returns r0 = 0x$(printf '%08x' "$UART2_DR")" \
    "$TMP/fur.out" check_fur

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
