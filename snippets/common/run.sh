#!/bin/sh
# poke-and-run (shared): poke the $BLOB_SIZE-byte buzz blob into panel SDRAM
# 0x650000 and blx it (the nana `fun` command: fun 0x650001 - the Thumb bit
# set). Success = byte-identical readback + the "fun 0x00650001: ok" reply.
# Everything talks to the panel only via tools/screen_probe.py.
#
# Parameterized by the per-folder shims (snippets/poke-and-run.{asm,c}/run.sh):
#   BLOB_SIZE  (required) expected buzz_blob.bin size in bytes
#   LABEL      (required) variant label, e.g. "asm" / "c"
# The shims also set HERE to their own folder so common.sh resolves BLOB to
# the per-folder buzz_blob.bin.
#
# Env: see common.sh (PANEL_PORT required). UI: ui.sh (brew-style steps).
#
# Exit codes: 0 = ok, 1 = a step failed, 2 = environment error (no PANEL_PORT,
# missing/stale blob).

for v in BLOB_SIZE LABEL; do
    eval "val=\${$v:-}"
    if [ -z "$val" ]; then
        echo "run.sh: $v must be set (per-folder shims set it; source of this call: ${0##*/})" >&2
        exit 2
    fi
done

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/common.sh"
. "$DIR/ui.sh"
start=$(date +%s.%N)

if [ ! -s "$BLOB" ] || [ "$(wc -c < "$BLOB")" -ne "$BLOB_SIZE" ]; then
    fail "buzz_blob.bin missing or not $BLOB_SIZE bytes - it is gitignored, build it first (see README)"
    exit 2
fi

step_init 6

step "liveness: console blob head at 0x79D448"
check_live "$TMP/live_before.bin" || exit 1

step "pre-poke: 8 bytes at 0x650000"
probe peek 0x650000 8

step "poke $BLOB_SIZE B to 0x650000 (one nana request)"
probe poke 0x650000 "@$BLOB"

step "verify readback ($BLOB_SIZE B)"
i=1
while [ $i -le 2 ]; do
    rm -f "$TMP/rd.bin"
    probe peek 0x650000 "$BLOB_SIZE" -w "$TMP/rd.bin" >/dev/null || true
    if [ -s "$TMP/rd.bin" ] && [ "$(wc -c < "$TMP/rd.bin")" -eq "$BLOB_SIZE" ] && head -c "$BLOB_SIZE" "$TMP/rd.bin" | cmp -s - "$BLOB"; then
        ok "poke verified ($BLOB_SIZE B, byte-identical)"
        break
    fi
    size=$( [ -s "$TMP/rd.bin" ] && wc -c < "$TMP/rd.bin" || echo missing )
    fail "readback mismatch (attempt $i/2, file: $size B) - retrying"
    i=$((i + 1))
done
[ $i -le 2 ] || { fail "poke did not stick after 2 attempts"; exit 1; }

step "blx the blob: fun 0x650001"
ack=$(printf 'fun 0x650001\nquit\n' | probe shell --wait 10)
if printf '%s\n' "$ack" | grep -q 'fun 0x00650001: ok'; then
    ok "fun 0x00650001: ok — the blob ran and returned"
else
    fail "no 'fun ... ok' reply; shell output was:"
    info "$ack"
    exit 1
fi

step "post liveness"
check_live "$TMP/live_after.bin" || {
    fail "no liveness after the blx. The panel may be hung; recovery is a power cycle"
    fail "ask the user before cycling power"
    exit 1
}

# Elapsed time: date +%s.%N on the dev box / rpi; if the result is not a
# decimal number (e.g. a date without %N), fall back to integer seconds.
is_dec() { case "$1" in ''|*[!0-9.]*) return 1 ;; esac; [ "$1" != "." ]; }
end=$(date +%s.%N)
if is_dec "$start" && is_dec "$end"; then
    elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')
else
    elapsed=$(awk -v e="$(date +%s)" 'BEGIN { printf "%.1f", e }')
fi
ok "Done in ${elapsed}s — panel live, 'ta-daa' should be audible (verify.sh for the register fingerprint)"
exit 0
