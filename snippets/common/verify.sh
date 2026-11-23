#!/bin/sh
# verify.sh: read back the TIM5 + SYS registers the buzz blob should have set,
# and fingerprint whether the melody actually ran (independent of whether the
# buzzer is audible). Panel I/O only via tools/screen_probe.py.
#
# Env: see common.sh (PANEL_PORT required). UI: ui.sh (brew-style steps).
#
# A completed "ta-daa" ends on note G6 with the counter stopped:
#   CR1:0x0000 PSC:0x0063 ARR:0x04FB CCR4:0x027D CCMR1:0x7070 CCMR2:0x7070 CCER:0x3333
# Verdict: ARR == 0 -> the blob never ran (or the region was reused);
#          ARR == 0x0782 (C6) -> bailed on the first note;
#          ARR == 0x04FB -> completed; anything else -> another owner wrote ARR.
#
# Pure POSIX sh (od + shell arithmetic + printf); no other languages.

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/common.sh"
. "$DIR/ui.sh"

step_init 3

step "liveness: console blob head at 0x79D448"
check_live "$TMP/live.bin" || exit 1

# name:addr:len — TIM5 register block first, then the SYS registers
REGS="tim5:0x40007400:68
enclk0:0x40000080:4
enclk2:0x40000088:4
ipswrst2:0x40000078:4
iomode8:0x400002E4:4
ioafr16:0x40000330:4"

step "readback: TIM5 block + SYS registers (6 peeks)"
for r in $REGS; do
    name=${r%%:*}
    rest=${r#*:}
    addr=${rest%%:*}
    len=${rest#*:}
    probe peek "$addr" "$len" -w "$TMP/$name.bin" >/dev/null || true
    info "  $name @ $addr"
done

for r in $REGS; do
    name=${r%%:*}
    [ -s "$TMP/$name.bin" ] || { fail "no data for $name (panel/console not in stage-0 state?)"; exit 1; }
done

step "verdict"

# VERIFY_DECODE_BEGIN
# Self-contained decode: reads the six peek files and prints the fingerprint
# table + verdict. No panel I/O, no external files, so it can be exercised
# standalone against synthetic peek files (a test harness extracts this
# section). Uses only od, shell arithmetic, and printf.

# Color (self-contained so the extracted section works standalone): on only
# when stdout is a TTY and NO_COLOR is not set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    ESC=$(printf '\033')
    V_GREEN="$ESC[32m"; V_RED="$ESC[31m"; V_RESET="$ESC[0m"
else
    V_GREEN=''; V_RED=''; V_RESET=''
fi

# u32le FILE OFFSET LABEL — print the 32-bit little-endian word at byte OFFSET
u32le() {
    set -- $(od -An -j "$2" -N 4 -t u1 "$1")
    [ $# -eq 4 ] || { echo "verify.sh: FAIL - $3: peek file too short" >&2; return 1; }
    echo $(( $1 + ($2 << 8) + ($3 << 16) + ($4 << 24) ))
}

# trow NAME VALUE EXPECTED — print one fingerprint table row (4-space indent,
# name padded to 7, value 0x%04x, green ✔ on match / red ✘ on mismatch) and
# append the mismatch to the global `mism` list. The `$(( ))` conversions
# normalize hex literals (POSIX sh's `[ -eq ]` would not parse `0x` itself).
trow() {
    v=$(( $2 )); e=$(( $3 ))
    if [ "$v" -eq "$e" ]; then
        printf '    %-7s0x%04x  %s✔%s\n' "$1" "$(( $2 & 0xFFFF ))" "$V_GREEN" "$V_RESET"
    else
        printf '    %-7s0x%04x  %s✘%s expected 0x%04x\n' "$1" "$(( $2 & 0xFFFF ))" "$V_RED" "$V_RESET" "$3"
        mism="$mism $1:0x$(printf '%x' "$2")!=exp 0x$(printf '%x' "$3")"
    fi
}

# verdict TIM5 ENCLK0 ENCLK2 IPSWRST2 IOMODE8 IOAFR16
verdict() {
    t=$1; e0=$2; e2=$3; r2=$4; i8=$5; a16=$6

    # TIM5 block, file offsets: CR1 0x00 CCMR1 0x18 CCMR2 0x1C CCER 0x20
    # CNT 0x24 PSC 0x28 ARR 0x2C CCR4 0x40
    cr1=$(u32le "$t" 0x00 tim5)    || return 1
    ccmr1=$(u32le "$t" 0x18 tim5)  || return 1
    ccmr2=$(u32le "$t" 0x1C tim5)  || return 1
    ccer=$(u32le "$t" 0x20 tim5)   || return 1
    cnt=$(u32le "$t" 0x24 tim5)    || return 1
    psc=$(u32le "$t" 0x28 tim5)    || return 1
    arr=$(u32le "$t" 0x2C tim5)    || return 1
    ccr4=$(u32le "$t" 0x40 tim5)   || return 1

    enclk0=$(u32le "$e0" 0 enclk0)    || return 1
    enclk2=$(u32le "$e2" 0 enclk2)    || return 1
    ipswrst2=$(u32le "$r2" 0 ipswrst2) || return 1
    iomode8=$(u32le "$i8" 0 iomode8)   || return 1
    ioafr16=$(u32le "$a16" 0 ioafr16)  || return 1

    # Fingerprint: the seven TIM5 words a completed melody leaves behind.
    # The SYS values are informational only, not part of the verdict.
    mism=""
    trow CR1   "$cr1"   0x0000
    trow PSC   "$psc"   0x0063
    trow ARR   "$arr"   0x04FB
    trow CCR4  "$ccr4"  0x027D
    trow CCMR1 "$ccmr1" 0x7070
    trow CCMR2 "$ccmr2" 0x7070
    trow CCER  "$ccer"  0x3333

    # One compact informational SYS line (same bit masks as the fingerprint).
    printf '  SYS: ENCLK0=0x%x ENCLK2=0x%x IPSWRST2=0x%x IOMODE8=0x%x IOAFR16=0x%04x\n' \
        "$((enclk0 & 0x02))" "$((enclk2 & 0x100000))" "$((ipswrst2 & 0x100000))" \
        "$((iomode8 & 0x40))" "$((ioafr16 & 0x5000))"

    # Verdict (logic unchanged).
    if [ "$arr" -eq 0 ]; then
        printf '  %s✘%s ARR==0 - the blob never ran (or the TIM5 region was reused)\n' "$V_RED" "$V_RESET"
    elif [ "$arr" -eq "$((0x0782))" ]; then
        printf '  %s✘%s ARR==0x0782 (C6) - bailed on the first note\n' "$V_RED" "$V_RESET"
    elif [ "$arr" -eq "$((0x04FB))" ] && [ -z "$mism" ]; then
        printf '  %s✔ FINGERPRINT MATCH%s — full ta-daa melody ran (ended on G6, counter stopped)\n' "$V_GREEN" "$V_RESET"
        printf '  (buzzer silence, if any, is a clock/pin issue, not code)\n'
    else
        arrhex=$(printf '%x' "$arr")
        printf '  %s✘ other owner%s — ARR=0x%s; mismatches:%s\n' "$V_RED" "$V_RESET" "$arrhex" "$mism"
    fi
}
# VERIFY_DECODE_END

verdict "$TMP/tim5.bin" "$TMP/enclk0.bin" "$TMP/enclk2.bin" \
    "$TMP/ipswrst2.bin" "$TMP/iomode8.bin" "$TMP/ioafr16.bin" || exit 1
