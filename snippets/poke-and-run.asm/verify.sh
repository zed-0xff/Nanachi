#!/bin/sh
# verify.sh: read back the TIM5 + SYS registers the buzz blob should have set,
# and fingerprint whether the melody actually ran (independent of whether the
# buzzer is audible). Panel I/O only via tools/screen_probe.py.
#
# Env: see common.sh (PANEL_PORT required, PANEL_IAC=1 optional).
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

echo "[1/8] liveness: console blob head at 0x79D448"
check_live "$TMP/live.bin" || exit 1

# name:addr:len — TIM5 register block first, then the SYS registers
REGS="tim5:0x40007400:68
enclk0:0x40000080:4
enclk2:0x40000088:4
ipswrst2:0x40000078:4
iomode8:0x400002E4:4
ioafr16:0x40000330:4"

echo "[2/8] readback: TIM5 block + SYS registers (6 peeks)"
i=1
for r in $REGS; do
    name=${r%%:*}
    rest=${r#*:}
    addr=${rest%%:*}
    len=${rest#*:}
    probe peek "$addr" "$len" -w "$TMP/$name.bin" >/dev/null || true
    echo "  [$((i + 1))/8] $name @ $addr"
    i=$((i + 1))
done

for r in $REGS; do
    name=${r%%:*}
    [ -s "$TMP/$name.bin" ] || { echo "verify.sh: FAIL - no data for $name (panel/console not in stage-0 state?)" >&2; exit 1; }
done

echo "[8/8] verdict"

# VERIFY_DECODE_BEGIN
# Self-contained decode: reads the six peek files and prints the fingerprint
# verdict. No panel I/O, no external files, so it can be exercised
# standalone against synthetic peek files (a test harness extracts this
# section). Uses only od, shell arithmetic, and printf.

# u32le FILE OFFSET LABEL — print the 32-bit little-endian word at byte OFFSET
u32le() {
    set -- $(od -An -j "$2" -N 4 -t u1 "$1")
    [ $# -eq 4 ] || { echo "verify.sh: FAIL - $3: peek file too short" >&2; return 1; }
    echo $(( $1 + ($2 << 8) + ($3 << 16) + ($4 << 24) ))
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

    printf '  TIM5:  CR1=0x%04x  PSC=0x%04x  ARR=0x%04x  CCR4=0x%04x\n' \
        "$((cr1 & 0xFFFF))" "$((psc & 0xFFFF))" "$((arr & 0xFFFF))" "$((ccr4 & 0xFFFF))"
    printf '         CCMR1=0x%04x  CCMR2=0x%04x  CCER=0x%04x  CNT=0x%04x\n' \
        "$((ccmr1 & 0xFFFF))" "$((ccmr2 & 0xFFFF))" "$((ccer & 0xFFFF))" "$((cnt & 0xFFFF))"
    printf '  SYS:   ENCLK0(GPIO)=0x%x  ENCLK2(TIM5)=0x%x  IPSWRST2=0x%x\n' \
        "$((enclk0 & 0x02))" "$((enclk2 & 0x100000))" "$((ipswrst2 & 0x100000))"
    printf '         IOMODE8 pin3=0x%x  IOAFR16=0x%04x\n' \
        "$((iomode8 & 0x40))" "$((ioafr16 & 0x5000))"

    # Fingerprint: the seven TIM5 words a completed melody leaves behind.
    # The SYS values above are informational only, not part of the verdict.
    mism=""
    chk() {
        e=$(( $3 ))
        [ "$2" -eq "$e" ] || mism="$mism $1:0x$(printf '%x' "$2")!=exp 0x$(printf '%x' "$e")"
    }
    chk CR1   "$cr1"   0x0000
    chk PSC   "$psc"   0x0063
    chk ARR   "$arr"   0x04FB
    chk CCR4  "$ccr4"  0x027D
    chk CCMR1 "$ccmr1" 0x7070
    chk CCMR2 "$ccmr2" 0x7070
    chk CCER  "$ccer"  0x3333

    if [ "$arr" -eq 0 ]; then
        echo "  verdict: ARR==0 - the blob never ran (or the TIM5 region was reused)"
    elif [ "$arr" -eq "$((0x0782))" ]; then
        echo "  verdict: ARR==0x0782 (C6) - bailed on the first note"
    elif [ "$arr" -eq "$((0x04FB))" ] && [ -z "$mism" ]; then
        echo "  verdict: FINGERPRINT MATCH - the full 'ta-daa' melody ran (ended on G6, counter stopped)"
        echo "  (buzzer silence, if any, is then a clock/pin issue, not code)"
    else
        echo "  verdict: other owner - ARR=0x$(printf '%x' "$arr"); mismatches: $mism"
    fi
}
# VERIFY_DECODE_END

verdict "$TMP/tim5.bin" "$TMP/enclk0.bin" "$TMP/enclk2.bin" \
    "$TMP/ipswrst2.bin" "$TMP/iomode8.bin" "$TMP/ioafr16.bin" || exit 1
