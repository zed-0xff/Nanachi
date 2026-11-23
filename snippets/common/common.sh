# common.sh — shared setup for the poke-and-run driver scripts. Sourced, not run.
#
# Env:
#   PANEL_PORT   (required) the serial URL, e.g. /dev/ttyUSB0 or socket://host:port

set -u

if [ -z "${PANEL_PORT:-}" ]; then
    echo "${0##*/}: PANEL_PORT is not set (e.g. export PANEL_PORT=/dev/ttyUSB0)" >&2
    exit 2
fi

# HERE/BLOB may be pre-set by the per-folder shims (snippets/poke-and-run.{asm,c}/
# run.sh, verify.sh) so BLOB points at the PER-FOLDER buzz_blob.bin, not this
# directory. Default: the directory of the script that sourced us.
HERE=${HERE:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PROBE="$ROOT/tools/screen_probe.py"
BLOB=${BLOB:-$HERE/buzz_blob.bin}

# The console blob head at the PEEK_BLOB_DST gap (0x79D448): present when the
# stage-0 image with the 0x2A1E console blob is running.
LIVE_HEAD="ffb5632000f039f8"  # push {r0-r7,lr} + movs r0, #'c' + bl pk_marker (the "chi!" console entry)

probe() { python3 "$PROBE" "$@"; }

# check_live FILE — non-zero unless the console blob is live; reads its head
# into FILE (8 bytes).
check_live() {
    live_file=$1
    rm -f "$live_file"
    probe peek 0x79D448 8 -w "$live_file" >/dev/null || true
    if [ ! -s "$live_file" ]; then
        echo "${0##*/}: liveness: no data at 0x79D448 - panel not in the stage-0 console state?" >&2
        return 1
    fi
    live_got=$(head -c 8 "$live_file" | od -An -tx1 | tr -d ' \n')
    if [ "$live_got" != "$LIVE_HEAD" ]; then
        echo "${0##*/}: liveness: blob head is $live_got, expected $LIVE_HEAD - is the stage-0 image with the peek blob running?" >&2
        return 1
    fi
    return 0
}
