#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  NEOSH // 新殻 — updater
#
#  Brings an existing install up to date with this checkout:
#    1. only with --pull: `git pull --ff-only` here first. It never merges or
#       rebases, and it stops if you have uncommitted changes to tracked files.
#       Without --pull nothing touches the network: the files in this
#       directory, local edits included, are what gets installed.
#    2. re-runs install.sh with the same choice as before (hook or --no-hook).
#  Settings, custom themes and the ~/.bashrc backup are kept, because the
#  installer never overwrites an existing config. If the installed files already
#  match this checkout, nothing is touched.
#
#  `neo update` runs this from the checkout recorded at install time.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
umask 022

main() {
    local SRC
    SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

    local PULL=0 FORCE=0 ALLOW_ROOT=0
    while (( $# )); do
        case $1 in
            --pull)       PULL=1 ;;
            --force)      FORCE=1 ;;
            --allow-root) ALLOW_ROOT=1 ;;
            -h|--help)    usage; exit 0 ;;
            *) printf 'update.sh: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    ui_init
    banner

    # ── what's installed ──
    [[ -n ${HOME-} && -d $HOME && -O $HOME ]] || die "HOME (${HOME-unset}) is not a directory you own."
    if (( EUID == 0 && ! ALLOW_ROOT )); then
        die "Running as root would update root's neosh, not yours. Run it as your user (or pass --allow-root)."
    fi
    local BASH_BIN
    BASH_BIN=$(type -P bash) || die "bash not found in PATH."
    local DATA=${XDG_DATA_HOME:-$HOME/.local/share}/neosh
    local MANIFEST=$DATA/install.manifest
    [[ -L $DATA ]] && die "$DATA is a symlink; refusing to update through it."
    [[ -f $DATA/neosh.bash ]] || die "neosh isn't installed for $(id -un) ($(tilde "$DATA") is empty). Run ./install.sh first."

    local OLD=unknown HOOK=1 RECORDED=
    [[ -f $DATA/VERSION ]] && IFS= read -r OLD < "$DATA/VERSION"
    if [[ -f $MANIFEST ]]; then
        [[ $(manifest_get "$MANIFEST" hook) == 0 ]] && HOOK=0
        RECORDED=$(manifest_get "$MANIFEST" source)
    fi
    local how='hook in ~/.bashrc'; (( HOOK )) || how='no hook'
    step "installed neosh $OLD ${G_SEP} $how" OK
    if [[ -n $RECORDED && $RECORDED != "$SRC" ]]; then
        note "It was installed from $(tilde "$RECORDED"); updating from $(tilde "$SRC") now."
    fi

    # ── pull ──
    # --pull was asked for explicitly, so anything that stops it is an error
    if (( ! PULL )); then
        step "source $(tilde "$SRC")" "LOCAL (--pull to git pull first)" dim
    elif ! type -P git >/dev/null; then
        die "--pull needs git, and git isn't installed. Nothing was installed."
    elif ! git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "--pull: $(tilde "$SRC") isn't a git checkout. Run ./update.sh without --pull to install it as it is."
    else
        local UP
        if ! UP=$(git -C "$SRC" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
            die "--pull: the current branch has no upstream to pull from. Nothing was installed."
        else
            git -C "$SRC" diff --quiet HEAD -- 2>/dev/null ||
                die "The checkout has uncommitted changes to tracked files. Commit or stash them, or run without --pull to install it as it is."
            local BEFORE AFTER
            BEFORE=$(git -C "$SRC" rev-parse HEAD)
            note "fetching $UP …"
            git -C "$SRC" pull --ff-only --quiet ||
                die "git pull --ff-only failed (has the branch diverged from $UP?). Nothing was installed."
            AFTER=$(git -C "$SRC" rev-parse HEAD)
            if [[ $BEFORE == "$AFTER" ]]; then
                step "git pull $UP" "ALREADY LATEST" dim
            else
                step "git pull ${BEFORE:0:7} ${G_ARROW} ${AFTER:0:7}" OK
                local line n=0
                while IFS= read -r line; do
                    (( ++n > 15 )) && { note "  … and more (git log ${BEFORE:0:7}..${AFTER:0:7})"; break; }
                    note "  ${G_SEP} $line"
                done < <(git -C "$SRC" log --no-decorate --format='%s' "$BEFORE..$AFTER" | tr -d '\000-\010\013-\037\177')
            fi
        fi
    fi

    # ── compare ──
    local f
    for f in install.sh lib/neosh.bash lib/neoshrc share/neosh.conf uninstall.sh VERSION; do
        [[ -f $SRC/$f ]] || die "missing $f, so this doesn't look like a complete neosh checkout."
    done
    local NEW
    IFS= read -r NEW < "$SRC/VERSION"
    if (( ! FORCE )) && [[ $RECORDED == "$SRC" ]] &&
       cmp -s -- "$SRC/lib/neosh.bash" "$DATA/neosh.bash" &&
       cmp -s -- "$SRC/lib/neoshrc" "$DATA/neoshrc" &&
       cmp -s -- "$SRC/share/neosh.conf" "$DATA/neosh.conf" &&
       cmp -s -- "$SRC/uninstall.sh" "$DATA/uninstall.sh" &&
       cmp -s -- "$SRC/VERSION" "$DATA/VERSION"; then
        step "runtime $(tilde "$DATA")" "UP TO DATE" dim
        printf '\n'
        say '(｀・ω・´)ゞ' "You're already on the newest neosh ($NEW), commander. Nothing to do!"
        printf '\n'
        exit 0
    fi
    step "update $OLD ${G_ARROW} $NEW" READY

    # ── reinstall (install.sh self-tests before it changes anything) ──
    local -a args=()
    (( HOOK )) || args+=(--no-hook)
    (( ALLOW_ROOT )) && args+=(--allow-root)
    "$BASH_BIN" "$SRC/install.sh" "${args[@]}" || die "install.sh failed, so the previous install is still in place."

    if [[ $OLD == "$NEW" ]]; then
        say '(・ω・)ノ' "Reinstalled neosh $NEW from $(tilde "$SRC")."
    else
        say '(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧' "Updated neosh $OLD ${G_ARROW} $NEW!"
    fi
    note "Shells that are already open keep the old version until you run: neo reload"
    printf '\n'
}

usage() {
    cat <<'EOF'
Usage: ./update.sh [options]      (or: neo update)

Reinstalls neosh from this directory over your existing install, local
edits included. Settings, custom themes and the hook choice are kept.

  --pull         git pull --ff-only first, to get the newest from GitHub
  --force        reinstall even if the installed files already match
  --allow-root   permit updating root's own install
  -h, --help     this help
EOF
}

# ── helpers (kept in sync with install.sh) ───────────────────────────────────
ui_init() {
    UI_UTF8=0
    local loc=${LC_ALL:-${LC_CTYPE:-${LANG-}}}
    [[ $loc == *[Uu][Tt][Ff]?(-)8* && ${TERM-} != linux ]] && UI_UTF8=1
    if [[ -t 1 && -z ${NO_COLOR-} && ${TERM-dumb} != dumb ]]; then
        C_A1=$'\e[38;2;62;243;255m' C_A2=$'\e[38;2;255;62;165m' C_DIM=$'\e[38;2;125;147;181m'
        C_FAINT=$'\e[38;2;69;86;122m' C_OK=$'\e[38;2;93;255;158m' C_WARN=$'\e[38;2;255;182;62m'
        C_CRIT=$'\e[38;2;255;59;92m' C_B=$'\e[1m' C_R=$'\e[0m'
    else
        C_A1= C_A2= C_DIM= C_FAINT= C_OK= C_WARN= C_CRIT= C_B= C_R=
    fi
    if (( UI_UTF8 )); then G_HEX='⬡' G_SEP='·' G_ARROW='→'; else G_HEX='<>' G_SEP='-' G_ARROW='->'; fi
}

banner() {
    local jp=; (( UI_UTF8 )) && jp=' // 新殻 更新シーケンス'
    printf '\n %s%s%s %sNEOSH UPDATER%s%s%s\n' "$C_A2" "$G_HEX" "$C_R" "$C_B$C_A1" "$C_R$C_DIM" "$jp" "$C_R"
}

step() {
    local label=$1 st=$2 col=$C_OK dots n
    case ${3-ok} in warn) col=$C_WARN ;; crit) col=$C_CRIT ;; dim) col=$C_DIM ;; esac
    n=$(( 50 - ${#label} )); (( n < 3 )) && n=3
    printf -v dots '%*s' "$n" ''
    printf '   %s%s %s%s %s%s%s\n' "$C_DIM" "$label" "$C_FAINT" "${dots// /.}" "$C_B$col" "$st" "$C_R"
}

note() { printf '   %s%s%s\n' "$C_DIM" "$1" "$C_R"; }

say() {
    local kao=$1; (( UI_UTF8 )) || kao='(^_^)'
    printf ' %s%s%s %sKAGARI »%s %s\n' "$C_A2" "$kao" "$C_R" "$C_B$C_A1" "$C_R" "$2"
}

die() {
    printf '\n' >&2
    local kao='(╥﹏╥)'; (( ${UI_UTF8:-0} )) || kao='(T_T)'
    printf ' %s%s%s %sKAGARI »%s %s\n\n' "${C_CRIT-}" "$kao" "${C_R-}" "${C_B-}${C_CRIT-}" "${C_R-}" "$1" >&2
    exit 1
}

tilde() { local p=$1; [[ $p == "$HOME"/* ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }

manifest_get() { # FILE KEY
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$2="* ]] && { printf '%s' "${line#*=}"; return 0; }
    done < "$1"
    return 0
}

# Parsed in full before it runs: `git pull` may replace this very file.
main "$@"
exit 0
