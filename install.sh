#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  NEOSH // 新殻 — installer
#
#  Installs for the current user only. No root, no network, no chsh:
#    ~/.local/share/neosh/      runtime (neosh.bash, neoshrc, uninstall.sh)
#    ~/.local/bin/neosh         launcher
#    ~/.config/neosh/neosh.conf settings (kept if it already exists)
#    ~/.bashrc                  a marked hook block appended at the end
#                               (a timestamped backup is made first)
#
#  Your login shell stays /bin/bash, so sshd, sudo, cron, scripts and recovery
#  shells are untouched, and a broken neosh can never lock you out.
#  Re-running it upgrades in place.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
umask 022

main() {
    local SRC
    SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

    local HOOK=1 THEME= BOOT= ALLOW_ROOT=0
    while (( $# )); do
        case $1 in
            --no-hook)    HOOK=0 ;;
            --theme)      THEME=${2-}; shift ;;
            --theme=*)    THEME=${1#*=} ;;
            --boot)       BOOT=${2-}; shift ;;
            --boot=*)     BOOT=${1#*=} ;;
            --allow-root) ALLOW_ROOT=1 ;;
            -h|--help)    usage; exit 0 ;;
            *) printf 'install.sh: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    ui_init
    banner

    # ── preflight ──
    [[ -n ${HOME-} && -d $HOME && -O $HOME ]] || die "HOME (${HOME-unset}) is not a directory you own."
    if (( EUID == 0 && ! ALLOW_ROOT )); then
        die "Running as root would install neosh for root, not for you. Run it as your user (use --allow-root if root really is the target)."
    fi
    local BASH_BIN
    BASH_BIN=$(type -P bash) || die "bash not found in PATH."
    local bv
    bv=$("$BASH_BIN" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"') || die "could not run $BASH_BIN"
    local maj=${bv%%.*} min=${bv#*.}
    (( maj > 4 || (maj == 4 && min >= 4) )) || die "neosh needs bash >= 4.4 (found $bv)."
    local f
    for f in lib/neosh.bash lib/neoshrc share/neosh.conf uninstall.sh VERSION; do
        [[ -f $SRC/$f ]] || die "missing $f, so this doesn't look like a complete neosh checkout."
    done
    local THEMES='hearth redline mecha sakura eclipse kurenai abyss aurum specter'
    if [[ -n $THEME && " $THEMES " != *" $THEME "* ]]; then die "unknown theme '$THEME' (choose: $THEMES)"; fi
    if [[ -n $BOOT && $BOOT != @(full|compact|off) ]]; then die "--boot must be full, compact or off"; fi
    "$BASH_BIN" -n "$SRC/lib/neosh.bash" || die "lib/neosh.bash has a syntax error."
    local VERSION
    IFS= read -r VERSION < "$SRC/VERSION"
    step "preflight ${G_SEP} bash $bv ${G_SEP} user ${USER:-$EUID}" OK

    local DATA=${XDG_DATA_HOME:-$HOME/.local/share}/neosh
    local CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/neosh
    local BIN_DIR=$HOME/.local/bin
    local LAUNCHER=$BIN_DIR/neosh
    local MARK_START='# >>> neosh >>>' MARK_END='# <<< neosh <<<'

    # ── runtime files (staged, then swapped in) ──
    if [[ -L $DATA ]]; then die "$DATA is a symlink; refusing to replace it."; fi
    if [[ -e $DATA && ! -f $DATA/neosh.bash && ! -f $DATA/install.manifest ]]; then
        die "$DATA exists but isn't a neosh install; refusing to overwrite it."
    fi
    mkdir -p -- "${DATA%/*}"
    local STAGE
    STAGE=$(mktemp -d -- "${DATA%/*}/.neosh-stage.XXXXXX")
    CLEANUP+=("$STAGE")
    install -m 644 -- "$SRC/lib/neosh.bash" "$SRC/lib/neoshrc" "$SRC/share/neosh.conf" "$SRC/VERSION" "$STAGE/"
    install -m 755 -- "$SRC/uninstall.sh" "$STAGE/uninstall.sh"
    # keep the previous manifest so the original backup path survives upgrades
    local PREV_BACKUP= PREV_CREATED=0
    if [[ -f $DATA/install.manifest ]]; then
        PREV_BACKUP=$(manifest_get "$DATA/install.manifest" backup)
        PREV_CREATED=$(manifest_get "$DATA/install.manifest" bashrc_created)
    fi

    # ── self-test: load the runtime in a clean interactive bash ──
    local out
    if ! out=$(env -i HOME="$HOME" PATH="$PATH" TERM=dumb LANG="${LANG-C.UTF-8}" \
              XDG_CONFIG_HOME="$STAGE/.selftest" NEOSH_BOOT=off \
              "$BASH_BIN" --norc --noprofile -i -c '. "$1" && __neo_selftest' _ "$STAGE/neosh.bash" \
              </dev/null 2>&1); then
        printf '%s\n' "$out" | grep -v 'job control\|terminal process group' >&2 || true
        die "self-test failed; nothing was changed."
    fi
    rm -rf -- "$STAGE/.selftest"
    step "self-test (runtime loads in bash $bv)" OK

    if [[ -e $DATA ]]; then
        local OLD="$DATA.old.$$"
        mv -- "$DATA" "$OLD"
        mv -- "$STAGE" "$DATA"
        rm -rf -- "$OLD"
    else
        mv -- "$STAGE" "$DATA"
    fi
    CLEANUP=()
    step "runtime ${G_ARROW} $(tilde "$DATA")" OK

    # ── launcher ──
    mkdir -p -- "$BIN_DIR"
    if [[ -e $LAUNCHER ]] && ! grep -q '^# neosh launcher' "$LAUNCHER" 2>/dev/null; then
        step "launcher ${G_ARROW} $(tilde "$LAUNCHER")" "SKIP (a different 'neosh' is there)" warn
    else
        local tmp
        tmp=$(mktemp -- "$LAUNCHER.XXXXXX")
        {
            printf '#!%s\n' "$BASH_BIN"
            printf '# neosh launcher (managed by neosh install.sh; removed by uninstall.sh)\n'
            printf '# No arguments: interactive bash with neosh. With arguments: exactly bash.\n'
            printf 'NEOSH_HOME=%q\n' "$DATA"
            printf 'BASH_BIN=%q\n' "$BASH_BIN"
            cat <<'EOF'
if (( $# )); then exec "$BASH_BIN" "$@"; fi
unset NEOSH_DISABLE
if [[ -r $NEOSH_HOME/neoshrc ]]; then exec "$BASH_BIN" --rcfile "$NEOSH_HOME/neoshrc" -i; fi
printf 'neosh: runtime missing in %s, starting plain bash\n' "$NEOSH_HOME" >&2
exec "$BASH_BIN" -i
EOF
        } > "$tmp"
        chmod 755 -- "$tmp"
        mv -f -- "$tmp" "$LAUNCHER"
        step "launcher ${G_ARROW} $(tilde "$LAUNCHER")" OK
    fi

    # ── config ──
    mkdir -p -- "$CONF_DIR"
    local CONF=$CONF_DIR/neosh.conf
    if [[ -e $CONF ]]; then
        step "config $(tilde "$CONF")" "KEPT" dim
    else
        install -m 644 -- "$SRC/share/neosh.conf" "$CONF"
        step "config ${G_ARROW} $(tilde "$CONF")" OK
    fi
    [[ -n $THEME ]] && conf_set "$CONF" theme "$THEME"
    [[ -n $BOOT ]] && conf_set "$CONF" boot "$BOOT"

    # ── ~/.bashrc hook ──
    local RC_LINK=$HOME/.bashrc RC BACKUP=$PREV_BACKUP CREATED=$PREV_CREATED HOOKED=0
    if (( HOOK )); then
        # Follow a symlinked ~/.bashrc (stow, chezmoi, yadm…) and edit its
        # target, so the link itself is preserved.
        if [[ -L $RC_LINK ]]; then
            RC=$(readlink -f -- "$RC_LINK") || die "~/.bashrc is a broken symlink."
        else
            RC=$RC_LINK
        fi
        if [[ -e $RC && ! -f $RC ]]; then die "$RC is not a regular file."; fi
        if [[ ! -e $RC ]]; then
            # A brand-new ~/.bashrc still gets the distro defaults.
            { printf '# .bashrc (created by neosh install.sh)\n'
              printf '[ -f /etc/bashrc ] && . /etc/bashrc\n'
              printf '[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc\n'; } > "$RC"
            CREATED=1
        fi
        [[ -w $RC ]] || die "$RC is not writable."

        local -a lines=() keep=()
        mapfile -t lines < "$RC"
        local skipping=0 l
        for l in "${lines[@]}"; do
            if [[ $l == "$MARK_START" ]]; then
                skipping=1
                # drop the blank separator line the installer added before the block
                if (( ${#keep[@]} )) && [[ -z ${keep[-1]} ]]; then unset 'keep[-1]'; fi
                continue
            fi
            if (( skipping )); then [[ $l == "$MARK_END" ]] && skipping=0; continue; fi
            keep+=("$l")
        done
        (( skipping )) && die "$RC has a '$MARK_START' line without a matching end marker; please fix it by hand."

        local tmp
        tmp=$(mktemp -- "${RC%/*}/.bashrc.neosh.XXXXXX")
        CLEANUP+=("$tmp")
        {
            (( ${#keep[@]} )) && printf '%s\n' "${keep[@]}"
            printf '\n%s\n' "$MARK_START"
            printf '# Managed by neosh install.sh; uninstall.sh (or `neo uninstall`) removes it.\n'
            printf '# One plain-bash session:  NEOSH_DISABLE=1 bash\n'
            printf 'if [[ $- == *i* && -z ${NEOSH_DISABLE-} && -r %q ]]; then\n' "$DATA/neosh.bash"
            printf '    . %q\n' "$DATA/neosh.bash"
            printf 'fi\n'
            printf '%s\n' "$MARK_END"
        } > "$tmp"
        "$BASH_BIN" -n "$tmp" || die "the updated ~/.bashrc failed a syntax check; nothing was changed."

        if cmp -s -- "$tmp" "$RC"; then
            rm -f -- "$tmp"
            step "hook ~/.bashrc" "UP TO DATE" dim
        else
            if [[ -z $BACKUP || ! -f $BACKUP ]] && (( ! CREATED )); then
                BACKUP="$HOME/.bashrc.neosh-backup.$(date +%Y%m%d-%H%M%S)"
                cp -p -- "$RC" "$BACKUP"
                step "backup ${G_ARROW} $(tilde "$BACKUP")" OK
            fi
            chmod --reference="$RC" -- "$tmp" 2>/dev/null || chmod 644 -- "$tmp"
            mv -f -- "$tmp" "$RC"
            step "hook ${G_ARROW} $(tilde "$RC")" OK
        fi
        CLEANUP=()
        HOOKED=1
    else
        RC=
        step "hook ~/.bashrc" "SKIPPED (--no-hook)" dim
    fi

    # ── manifest (plain key=value; uninstall.sh parses it, never sources it) ──
    {
        printf 'version=%s\n' "$VERSION"
        printf 'installed=%s\n' "$(date +%Y-%m-%dT%H:%M:%S)"
        printf 'bashrc=%s\n' "$RC"
        printf 'bashrc_created=%s\n' "$CREATED"
        printf 'backup=%s\n' "$BACKUP"
        printf 'launcher=%s\n' "$LAUNCHER"
        printf 'hook=%s\n' "$HOOKED"
    } > "$DATA/install.manifest"

    if [[ :$PATH: != *:"$BIN_DIR":* ]]; then
        step "PATH contains ~/.local/bin" "NO" warn
        note "Add ~/.local/bin to PATH to use the 'neosh' command (the hook works without it)."
    fi

    if (( UI_UTF8 )); then printf '   %s>> 導入完了 — neosh %s installed%s\n\n' "$C_OK$C_B" "$VERSION" "$C_R"
    else printf '   %s>> install complete - neosh %s%s\n\n' "$C_OK$C_B" "$VERSION" "$C_R"; fi
    if (( HOOKED )); then
        say '(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧' "All set, commander! Open a new terminal (or run: exec bash) to light the hearth."
    else
        say '(｀・ω・´)ゞ' "Installed without the hook. Run 'neosh' whenever you want the HUD."
    fi
    printf '\n   %sneo help%s      command deck\n' "$C_A1" "$C_R"
    printf '   %sneo theme%s     pick one of 9 themes\n' "$C_A1" "$C_R"
    printf '   %s./uninstall.sh%s  back to plain bash\n\n' "$C_A1" "$C_R"
}

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Installs neosh for the current user and hooks it into ~/.bashrc.

  --theme NAME   hearth redline mecha sakura eclipse kurenai abyss aurum specter
  --boot MODE    full | compact | off   (startup banner)
  --no-hook      don't touch ~/.bashrc; start neosh with the `neosh` command
  --allow-root   permit installing into root's own home
  -h, --help     this help
EOF
}

# ── helpers ──────────────────────────────────────────────────────────────────
CLEANUP=()
on_exit() { local p; for p in "${CLEANUP[@]}"; do [[ -n $p ]] && rm -rf -- "$p"; done; }
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
    if (( UI_UTF8 )); then G_HEX='⬡' G_SEP='·' G_ARROW='→'; else G_HEX='<>' G_SEP='-' G_ARROW='->'; fi
}

banner() {
    local jp=; (( UI_UTF8 )) && jp=' // 新殻 導入シーケンス'
    printf '\n %s%s%s %sNEOSH INSTALLER%s%s%s\n' "$C_A2" "$G_HEX" "$C_R" "$C_B$C_A1" "$C_R$C_DIM" "$jp" "$C_R"
}

# step LABEL STATUS [ok|warn|crit|dim]
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

conf_set() { # FILE KEY VALUE (atomic)
    local f=$1 key=$2 val=$3 tmp line found=0
    tmp=$(mktemp -- "$f.XXXXXX")
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
            (( found )) || printf '%s=%s\n' "$key" "$val"; found=1
        else printf '%s\n' "$line"; fi
    done < "$f" > "$tmp"
    (( found )) || printf '%s=%s\n' "$key" "$val" >> "$tmp"
    chmod 644 -- "$tmp"; mv -f -- "$tmp" "$f"
    step "config $key=$val" OK
}

# Parse everything before running anything, so editing or replacing this file
# while it runs can't change what it does halfway through.
main "$@"
exit 0
