#!/bin/sh
# poke-and-run (C): poke the 300-byte buzz blob (compiled from buzz_blob.c) into
# panel SDRAM 0x650000 and blx it (the nana `fun` command: fun 0x650001 - the
# Thumb bit set). Success = byte-identical readback + the "fun 0x00650001: ok"
# reply. Everything talks to the panel only via tools/screen_probe.py.
#
# Env: see common.sh (PANEL_PORT required).
#
# Exit codes: 0 = ok, 1 = a step failed, 2 = environment error (no PANEL_PORT,
# missing/stale blob).

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/common.sh"

if [ ! -s "$BLOB" ] || [ "$(wc -c < "$BLOB")" -ne 300 ]; then
    echo "run.sh: buzz_blob.bin missing or not 300 bytes - it is gitignored, build it first (see README)." >&2
    exit 2
fi

echo "[1/6] liveness: console blob head at 0x79D448"
check_live "$TMP/live_before.bin" || exit 1

echo "[2/6] pre-poke: 8 bytes at 0x650000 (stdout dump)"
probe peek 0x650000 8

echo "[3/6] poke 300 bytes to 0x650000 (@file; under the 4045-byte poke cap - one nana request)"
probe poke 0x650000 "@$BLOB"

echo "[4/6] verify: fresh-console 300-byte readback, cmp with the blob"
i=1
while [ $i -le 2 ]; do
    rm -f "$TMP/rd.bin"
    probe peek 0x650000 300 -w "$TMP/rd.bin" >/dev/null || true
    if [ -s "$TMP/rd.bin" ] && [ "$(wc -c < "$TMP/rd.bin")" -eq 300 ] && head -c 300 "$TMP/rd.bin" | cmp -s - "$BLOB"; then
        echo "run.sh: readback byte-identical (300 B)"
        break
    fi
    size=$( [ -s "$TMP/rd.bin" ] && wc -c < "$TMP/rd.bin" || echo missing )
    echo "run.sh: attempt $i/2 readback mismatch (file: $size B) - retrying"
    i=$((i + 1))
done
[ $i -le 2 ] || { echo "run.sh: poke did not stick after 2 attempts" >&2; exit 1; }

echo "[5/6] blx the blob: fun 0x650001 (expect the 'fun 0x00650001: ok' reply)"
ack=$(printf 'fun 0x650001\nquit\n' | probe shell --wait 10)
if printf '%s\n' "$ack" | grep -q 'fun 0x00650001: ok'; then
    echo "run.sh: fun ok received (the blob ran and returned)"
else
    echo "run.sh: no 'fun ... ok' reply; shell output was:"
    printf '%s\n' "$ack"
    exit 1
fi

echo "[6/6] post: liveness re-check"
check_live "$TMP/live_after.bin" || {
    echo "run.sh: FAILED - no liveness after the blx. The panel may be hung; recovery is a power cycle." >&2
    echo "run.sh: ask the user before cycling power." >&2
    exit 1
}

echo "run.sh: OK - poked, blx'd (fun ok), panel still live."
echo "run.sh: (is the 'ta-daa' audible? if not, run verify.sh for the register fingerprint)"
exit 0
