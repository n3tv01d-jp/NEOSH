#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  NEOSH // 新殻 — uninstaller
#
#  Puts you back on plain bash + your own ~/.bashrc:
#    · removes only the marked neosh block from ~/.bashrc (everything you
#      added before or after it stays exactly as it is)
#    · removes ~/.local/bin/neosh (only if it's the neosh launcher)
#    · removes ~/.local/share/neosh
#    · if your login shell was ever pointed at neosh, sets it back to bash
#    · keeps ~/.config/neosh and the .bashrc backup unless you pass --purge
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
umask 022

main() {
    local YES=0 PURGE=0
    while (( $# )); do
        case $1 in
            -y|--yes)  YES=1 ;;
            --purge)   PURGE=1 ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'uninstall.sh: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    ui_init
    banner
    [[ -n ${HOME-} && -d $HOME ]] || die "HOME is not set to a directory."

    local DATA=${XDG_DATA_HOME:-$HOME/.local/share}/neosh
    local CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/neosh
    local MANIFEST=$DATA/install.manifest
    local MARK_START='# >>> neosh >>>' MARK_END='# <<< neosh <<<'

    local RC= LAUNCHER=$HOME/.local/bin/neosh BACKUP= CREATED=0
    if [[ -f $MANIFEST ]]; then
        RC=$(manifest_get "$MANIFEST" bashrc)
        BACKUP=$(manifest_get "$MANIFEST" backup)
        CREATED=$(manifest_get "$MANIFEST" bashrc_created)
        local l; l=$(manifest_get "$MANIFEST" launcher); [[ -n $l ]] && LAUNCHER=$l
    else
        note "No install manifest found; cleaning up the default locations."
    fi
    [[ $CREATED == 1 ]] || CREATED=0
    # always look at the real ~/.bashrc too (it may have been re-linked since)
    local RC_HOME=$HOME/.bashrc
    [[ -L $RC_HOME ]] && RC_HOME=$(readlink -f -- "$RC_HOME" 2>/dev/null || printf '%s' "$RC_HOME")

    if (( ! YES )); then
        if [[ ! -t 0 ]]; then die "Not a terminal, so I can't ask. Re-run with -y to confirm."; fi
        local ans
        printf '   %sRemove neosh and go back to plain bash?%s [y/N] ' "$C_B" "$C_R"
        read -r ans || ans=
        [[ $ans == [yY]* ]] || { say '(・ω・)ノ' "Okay! Nothing was changed."; exit 0; }
    fi

    # ── login shell ──
    # The installer never changes it, but if it was pointed at neosh by hand,
    # put it back to bash *before* deleting the launcher it points at.
    local USERNAME login_shell=
    USERNAME=$(id -un)
    if command -v getent >/dev/null; then
        login_shell=$(getent passwd "$USERNAME" | cut -d: -f7) || login_shell=
    fi
    if [[ $login_shell == *neosh* ]]; then
        local BASH_BIN; BASH_BIN=$(type -P bash || printf /bin/bash)
        if chsh -s "$BASH_BIN" "$USERNAME"; then step "login shell ${G_ARROW} $BASH_BIN" OK
        else
            step "login shell ${G_ARROW} $BASH_BIN" FAILED crit
            die "Couldn't change your login shell back. Run 'chsh -s $BASH_BIN' first, then run this again."
        fi
    else
        step "login shell is ${login_shell:-unknown}" "UNCHANGED" dim
    fi

    # ── ~/.bashrc hook ──
    local -A done_rc=()
    local target
    for target in "$RC" "$RC_HOME"; do
        [[ -n $target && -z ${done_rc[$target]-} ]] || continue
        done_rc[$target]=1
        unhook "$target"
    done

    # ── launcher ──
    if [[ -f $LAUNCHER ]] && grep -q '^# neosh launcher' "$LAUNCHER" 2>/dev/null; then
        rm -f -- "$LAUNCHER"
        step "launcher $(tilde "$LAUNCHER")" REMOVED
    elif [[ -e $LAUNCHER ]]; then
        step "launcher $(tilde "$LAUNCHER")" "KEPT (not ours)" warn
    else
        step "launcher" "NOT PRESENT" dim
    fi

    # ── runtime ──
    if [[ -L $DATA ]]; then
        step "runtime $(tilde "$DATA")" "KEPT (symlink)" warn
    elif [[ -d $DATA ]]; then
        if [[ -f $DATA/neosh.bash || -f $MANIFEST ]]; then
            rm -rf -- "$DATA"
            step "runtime $(tilde "$DATA")" REMOVED
        else
            step "runtime $(tilde "$DATA")" "KEPT (not ours)" warn
        fi
    else
        step "runtime" "NOT PRESENT" dim
    fi

    # ── config ──
    if (( PURGE )); then
        if [[ -d $CONF_DIR && ! -L $CONF_DIR && ${CONF_DIR##*/} == neosh ]]; then
            rm -rf -- "$CONF_DIR"
            step "config $(tilde "$CONF_DIR")" REMOVED
        fi
        if [[ -n $BACKUP && -f $BACKUP && ${BACKUP##*/} == .bashrc.neosh-backup.* ]]; then
            rm -f -- "$BACKUP"
            step "backup $(tilde "$BACKUP")" REMOVED
        fi
    else
        [[ -d $CONF_DIR ]] && step "config $(tilde "$CONF_DIR")" "KEPT (--purge removes)" dim
        [[ -n $BACKUP && -f $BACKUP ]] && step "backup $(tilde "$BACKUP")" "KEPT" dim
    fi

    if (( UI_UTF8 )); then printf '   %s>> 撤去完了 — back to plain bash%s\n\n' "$C_OK$C_B" "$C_R"
    else printf '   %s>> removed - back to plain bash%s\n\n' "$C_OK$C_B" "$C_R"; fi
    say '(｡･ω･)ﾉﾞ' "Hearth banked. New terminals start in plain bash with your own ~/.bashrc. Run 'exec bash' to reset this one. See you, commander."
    printf '\n'
}

# Remove the marked block from one rc file, atomically and syntax-checked.
unhook() {
    local rc=$1
    if [[ ! -f $rc ]]; then return 0; fi
    if ! grep -qxF -- "$MARK_START" "$rc"; then
        step "hook $(tilde "$rc")" "NOT PRESENT" dim
        return 0
    fi
    [[ -w $rc ]] || die "$rc is not writable."
    local -a lines=() keep=()
    mapfile -t lines < "$rc"
    local skipping=0 l
    for l in "${lines[@]}"; do
        if [[ $l == "$MARK_START" ]]; then
            skipping=1
            if (( ${#keep[@]} )) && [[ -z ${keep[-1]} ]]; then unset 'keep[-1]'; fi
            continue
        fi
        if (( skipping )); then [[ $l == "$MARK_END" ]] && skipping=0; continue; fi
        keep+=("$l")
    done
    (( skipping )) && die "$rc has '$MARK_START' without '$MARK_END'; please remove the block by hand."

    # created by the installer and nothing else added? then remove the file.
    if (( CREATED )) && [[ $rc == "$RC" ]]; then
        local only_ours=1
        for l in "${keep[@]}"; do
            case $l in
                ''|'# .bashrc (created by neosh install.sh)'|'[ -f /etc/bashrc ] && . /etc/bashrc'|'[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc') ;;
                *) only_ours=0; break ;;
            esac
        done
        if (( only_ours )); then
            rm -f -- "$rc"
            step "~/.bashrc (created by neosh)" REMOVED
            return 0
        fi
    fi

    local tmp
    tmp=$(mktemp -- "${rc%/*}/.bashrc.neosh.XXXXXX")
    CLEANUP+=("$tmp")
    if (( ${#keep[@]} )); then printf '%s\n' "${keep[@]}" > "$tmp"; else : > "$tmp"; fi
    bash -n "$tmp" || die "$rc would fail a syntax check without the block; left unchanged."
    chmod --reference="$rc" -- "$tmp" 2>/dev/null || chmod 644 -- "$tmp"
    mv -f -- "$tmp" "$rc"
    step "unhook $(tilde "$rc")" OK
}

usage() {
    cat <<'EOF'
Usage: ./uninstall.sh [options]      (or: neo uninstall)

Removes neosh and returns you to plain bash with your own ~/.bashrc.

  -y, --yes   don't ask for confirmation
  --purge     also delete ~/.config/neosh and the ~/.bashrc backup
  -h, --help  this help
EOF
}

# ── helpers (kept in sync with install.sh) ───────────────────────────────────
CLEANUP=()
on_exit() { local p; for p in "${CLEANUP[@]}"; do [[ -n $p ]] && rm -f -- "$p"; done; }
trap on_exit EXIT

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
    if (( UI_UTF8 )); then G_HEX='⬡' G_ARROW='→'; else G_HEX='<>' G_ARROW='->'; fi
}

banner() {
    local jp=; (( UI_UTF8 )) && jp=' // 新殻 撤去シーケンス'
    printf '\n %s%s%s %sNEOSH UNINSTALLER%s%s%s\n' "$C_A2" "$G_HEX" "$C_R" "$C_B$C_A1" "$C_R$C_DIM" "$jp" "$C_R"
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

manifest_get() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$2="* ]] && { printf '%s' "${line#*=}"; return 0; }
    done < "$1"
    return 0
}

# Parsed fully before it runs, so deleting ~/.local/share/neosh (where
# `neo uninstall` runs this from) mid-way is safe.
main "$@"
exit 0
