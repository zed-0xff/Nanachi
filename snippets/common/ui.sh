# ui.sh — brew-style output helpers for the poke-and-run driver scripts.
# Sourced, not run. Pure POSIX sh: no dependencies beyond sh builtins and
# `[ -t 1 ]`.

# Color: on only when stdout is a TTY and NO_COLOR is not set (non-empty).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    ESC=$(printf '\033')
    C_GREEN="$ESC[32m"
    C_RED="$ESC[31m"
    C_CYAN="$ESC[36m"
    C_RESET="$ESC[0m"
else
    C_GREEN=''
    C_RED=''
    C_CYAN=''
    C_RESET=''
fi

STEP_N=0
STEP_TOTAL=0

# step_init TOTAL — set the total number of steps (call once, before `step`).
step_init() {
    STEP_TOTAL=$1
    STEP_N=0
}

# step "label" — print `==> [N/total] label` with a cyan `==>`; N is internal.
step() {
    STEP_N=$((STEP_N + 1))
    printf '%s==> [%d/%d]%s %s\n' "$C_CYAN" "$STEP_N" "$STEP_TOTAL" "$C_RESET" "$1"
}

# ok "msg" — print `✔ msg` in green.
ok() {
    printf '%s✔ %s%s\n' "$C_GREEN" "$1" "$C_RESET"
}

# fail "msg" — print `✘ msg` in red to stderr.
fail() {
    printf '%s✘ %s%s\n' "$C_RED" "$1" "$C_RESET" >&2
}

# info "msg" — plain uncolored line (detail dumps).
info() {
    printf '%s\n' "$1"
}
