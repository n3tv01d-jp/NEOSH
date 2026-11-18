# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
#  NEOSH // 新殻インターフェース — HUD layer for GNU bash
#
#  neosh is not a re-implementation of bash. It's a layer loaded on top of your
#  normal interactive bash (after /etc/bashrc and ~/.bashrc), so the parser,
#  builtins, job control, completion, history, restricted mode and every
#  security fix stay the same as the bash your distro ships and patches.
#
#  Design rules:
#    · only interactive shells: scripts, `bash -c`, scp/rsync never see it
#    · never `eval`s or sources data it didn't ship (config is parsed, not run)
#    · dynamic text (paths, branch names) never goes through prompt expansion
#    · no external programs per prompt except an optional `git status`
# ─────────────────────────────────────────────────────────────────────────────

[[ $- == *i* ]] || return 0
[[ -n ${__NEOSH_LOADED-} ]] && return 0
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'neosh: bash >= 4.4 required (this is %s); staying on plain bash\n' "$BASH_VERSION" >&2
    return 0
fi
__NEOSH_LOADED=1
NEOSH_VERSION=1.0.0
NEOSH_HOME=${BASH_SOURCE[0]%/*}
[[ $NEOSH_HOME == "${BASH_SOURCE[0]}" ]] && NEOSH_HOME=.
NEOSH_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/neosh/neosh.conf

# ── themes (same palettes as HEARTH; accent roles a1/a2/a3, dim, faint) ──────
declare -gA __neo_theme_jp=(
    [hearth]=炉心 [redline]=赤警報 [mecha]=機甲 [sakura]=桜 [eclipse]=月蝕
    [kurenai]=紅 [abyss]=深海 [aurum]=黄金 [specter]=幽霊
)
__neo_theme_order=(hearth redline mecha sakura eclipse kurenai abyss aurum specter)
declare -gA __neo_theme_rgb=(
    #           a1            a2            a3            dim           faint
    [hearth]="62,243,255   255,62,165   155,123,255  125,147,181  69,86,122"
    [redline]="255,106,61  255,210,63   255,154,118  181,138,125  110,74,66"
    [mecha]="141,255,92    255,225,77   77,255,210   134,169,130  71,97,63"
    [sakura]="255,154,213  143,220,255  212,179,255  180,138,166  107,74,99"
    [eclipse]="195,166,255 255,203,92   127,180,255  141,134,181  76,70,117"
    [kurenai]="255,46,77   255,138,138  194,26,58    181,122,130  110,58,66"
    [abyss]="47,155,255    62,255,193   90,107,255   122,151,184  60,84,117"
    [aurum]="255,201,74    255,241,184  217,139,43   181,162,122  110,95,62"
    [specter]="230,238,247 159,180,201  110,130,150  140,150,162  76,85,96"
)
# status colours never change with the theme (same rule as HEARTH)
__neo_status_rgb="93,255,158 255,182,62 255,59,92"

# ── config ───────────────────────────────────────────────────────────────────
declare -gA __neo_cfg=(
    [theme]=hearth [boot]=compact [color]=auto [glyphs]=auto [prompt]=on
    [navigator]=on [clock]=on [git]=on [git_dirty]=on [title]=on [spacing]=on
    [duration]=3 [path_depth]=4
)

# __neo_valid KEY VALUE → 0 if acceptable
__neo_valid() {
    case $1 in
        theme)      [[ -n ${__neo_theme_rgb[$2]+x} ]] ;;
        boot)       [[ $2 == @(full|compact|off) ]] ;;
        color)      [[ $2 == @(auto|truecolor|256|off) ]] ;;
        glyphs)     [[ $2 == @(auto|unicode|ascii) ]] ;;
        prompt|navigator|clock|git|git_dirty|title|spacing) [[ $2 == @(on|off) ]] ;;
        duration)   [[ $2 =~ ^[0-9]{1,4}$ ]] ;;
        path_depth) [[ $2 =~ ^[0-9]{1,2}$ ]] && (( 10#$2 >= 1 )) ;;
        *) return 1 ;;
    esac
}

# The config is *parsed*, never sourced: only known keys with validated values
# are accepted, so a tampered file can at worst change a colour.
__neo_cfg_load() {
    local f=$NEOSH_CONFIG line k v n=0
    if [[ ! -f $f || ! -r $f ]]; then :
    elif [[ ! -O $f ]]; then
        printf 'neosh: ignoring %s (not owned by you)\n' "$f" >&2
    else
    while IFS= read -r line || [[ -n $line ]]; do
        (( ++n > 500 )) && break
        line=${line%%#*}
        [[ $line =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*([A-Za-z0-9_.-]*)[[:space:]]*$ ]] || continue
        k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
        if __neo_valid "$k" "$v"; then __neo_cfg[$k]=$v
        else printf 'neosh: config: ignoring bad value %s=%s\n' "$k" "$v" >&2; fi
    done < "$f"
    fi
    # environment overrides for one-off sessions, e.g. NEOSH_THEME=sakura bash
    [[ -n ${NEOSH_THEME-} ]] && __neo_valid theme "$NEOSH_THEME" && __neo_cfg[theme]=$NEOSH_THEME
    [[ -n ${NEOSH_BOOT-} ]] && __neo_valid boot "$NEOSH_BOOT" && __neo_cfg[boot]=$NEOSH_BOOT
    return 0
}

# Rewrite one key atomically (temp file in the same dir + rename).
__neo_cfg_save() {
    local key=$1 val=$2 f=$NEOSH_CONFIG dir tmp line found=0
    __neo_valid "$key" "$val" || { printf 'neosh: invalid value for %s: %s\n' "$key" "$val" >&2; return 1; }
    dir=${f%/*}
    [[ -d $dir ]] || mkdir -p -m 700 -- "$dir" || return 1
    [[ -e $f ]] || : > "$f" || return 1
    tmp=$(mktemp -- "$f.XXXXXX") || return 1
    {
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
                (( found )) || printf '%s=%s\n' "$key" "$val"; found=1
            else
                printf '%s\n' "$line"
            fi
        done < "$f"
        (( found )) || printf '%s=%s\n' "$key" "$val"
    } > "$tmp" && chmod 644 -- "$tmp" && mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
    __neo_cfg[$key]=$val
}

# ── terminal capabilities ────────────────────────────────────────────────────
__neo_detect() {
    local loc=${LC_ALL:-${LC_CTYPE:-${LANG-}}}
    __neo_utf8=0
    if [[ ${__neo_cfg[glyphs]} == unicode ]] ||
       { [[ ${__neo_cfg[glyphs]} == auto && $loc == *[Uu][Tt][Ff]?(-)8* && $TERM != linux ]]; }; then
        __neo_utf8=1
    fi
    __neo_depth=0
    case ${__neo_cfg[color]} in
        off) ;;
        truecolor) __neo_depth=24 ;;
        256) __neo_depth=8 ;;
        auto)
            if [[ -n ${NO_COLOR-} || $TERM == dumb || -z $TERM ]]; then __neo_depth=0
            elif [[ ${COLORTERM-} == @(truecolor|24bit) || $TERM == *@(kitty|direct|truecolor|24bit|alacritty|wezterm|foot|ghostty)* ]]; then __neo_depth=24
            else __neo_depth=8; fi ;;
    esac
}

# __neo_sgr "r,g,b" → $__neo_esc (foreground escape for the colour depth)
__neo_sgr() {
    local r g b
    IFS=, read -r r g b <<< "$1"
    case $__neo_depth in
        24) __neo_esc=$'\e[38;2;'"$r;$g;${b}m" ;;
        8)  local c=0 v
            for v in "$r" "$g" "$b"; do
                (( c = c * 6 + (v < 48 ? 0 : v < 115 ? 1 : (v - 35) / 40) ))
            done
            __neo_esc=$'\e[38;5;'"$((16 + c))m" ;;
        *)  __neo_esc= ;;
    esac
}

__neo_palette() {
    local -a rgb st
    read -ra rgb <<< "${__neo_theme_rgb[${__neo_cfg[theme]}]}"
    read -ra st <<< "$__neo_status_rgb"
    declare -gA __neo_c=()
    local i names=(a1 a2 a3 dim faint)
    for i in 0 1 2 3 4; do __neo_sgr "${rgb[i]}"; __neo_c[${names[i]}]=$__neo_esc; done
    __neo_sgr "${st[0]}"; __neo_c[ok]=$__neo_esc
    __neo_sgr "${st[1]}"; __neo_c[warn]=$__neo_esc
    __neo_sgr "${st[2]}"; __neo_c[crit]=$__neo_esc
    if (( __neo_depth )); then
        __neo_c[b]=$'\e[1m' __neo_c[r]=$'\e[0m'
    else
        __neo_c[b]= __neo_c[r]=
    fi
}

__neo_glyphset() {
    declare -gA __neo_g
    if (( __neo_utf8 )); then
        __neo_g=( [tl]='╭─' [bl]='╰─' [arrow]='▶' [fill]='─' [lb]='◢' [rb]='◣' [lp]='⟨' [rp]='⟩'
                  [branch]='⎇' [dirty]='●' [clean]='✓' [fail]='✖' [time]='⏱' [clock]='炉'
                  [jobs]='⚙' [ssh]='⇄' [box]='⬢' [venv]='⌬' [root]='⚠' [hex]='⬡' [ell]='…' [cont]='┊'
                  [bar]='█' [bar0]='░' [sep]='·' )
    else
        __neo_g=( [tl]='.-' [bl]="'-" [arrow]='>' [fill]='-' [lb]='[' [rb]=']' [lp]='(' [rp]=')'
                  [branch]='git:' [dirty]='*' [clean]='=' [fail]='x' [time]='t' [clock]=''
                  [jobs]='&' [ssh]='ssh' [box]='box' [venv]='py' [root]='!' [hex]='<>' [ell]='...' [cont]='|'
                  [bar]='#' [bar0]='.' [sep]='-' )
    fi
}

# ── text helpers ─────────────────────────────────────────────────────────────
# Display width of $1 → $__neo_w (CJK / fullwidth = 2 cells, combining = 0)
__neo_width() {
    local s=$1 t i n w
    t=${s//[[:ascii:]]/}
    w=$(( ${#s} - ${#t} ))
    for (( i = 0; i < ${#t}; i++ )); do
        printf -v n '%d' "'${t:i:1}"
        if (( (n >= 0x300 && n <= 0x36F) || (n >= 0x1AB0 && n <= 0x1AFF) || (n >= 0x1DC0 && n <= 0x1DFF) ||
              (n >= 0x200B && n <= 0x200F) || (n >= 0x20D0 && n <= 0x20FF) || (n >= 0xFE00 && n <= 0xFE0F) ||
              (n >= 0xFE20 && n <= 0xFE2F) )); then
            :   # combining / zero-width
        elif (( (n >= 0x1100 && n <= 0x115F) || (n >= 0x2E80 && n <= 0x303E) || (n >= 0x3041 && n <= 0x33FF) ||
                (n >= 0x3400 && n <= 0x4DBF) || (n >= 0x4E00 && n <= 0x9FFF) || (n >= 0xA000 && n <= 0xA4CF) ||
                (n >= 0xAC00 && n <= 0xD7A3) || (n >= 0xF900 && n <= 0xFAFF) || (n >= 0xFE30 && n <= 0xFE4F) ||
                (n >= 0xFF00 && n <= 0xFF60) || (n >= 0xFFE0 && n <= 0xFFE6) || (n >= 0x1F300 && n <= 0x1F64F) ||
                (n >= 0x1F900 && n <= 0x1F9FF) || (n >= 0x20000 && n <= 0x3FFFD) )); then
            (( w += 2 ))   # CJK / fullwidth / emoji
        else
            (( w += 1 ))
        fi
    done
    __neo_w=$w
}

# Strip control characters (ESC, \001, \002, newlines…) from untrusted text so
# a directory or branch name can't inject terminal escape sequences.
__neo_clean() { __neo_s=${1//[[:cntrl:]]/?}; }

# ── navigator KAGARI ─────────────────────────────────────────────────────────
# __neo_say KAO MESSAGE [JP]
__neo_say() {
    [[ ${__neo_cfg[navigator]} == on ]] || return 0
    local kao=$1
    (( __neo_utf8 )) || kao='(^_^)'
    printf ' %s%s%s %sKAGARI »%s %s' "${__neo_c[a2]}" "$kao" "${__neo_c[r]}" "${__neo_c[b]}${__neo_c[a1]}" "${__neo_c[r]}" "$2"
    if [[ -n ${3-} ]] && (( __neo_utf8 )); then printf '  %s%s%s' "${__neo_c[dim]}" "$3" "${__neo_c[r]}"; fi
    printf '\n'
}

__neo_greeting() {
    local h
    printf -v h '%(%H)T' -1
    h=$((10#$h))
    if   (( h < 5 ));  then __neo_say '(￣o￣) zzz' "Still up at $(printf '%(%H:%M)T' -1), commander? I'll keep the hearth warm." '夜更かしですね…'
    elif (( h < 11 )); then __neo_say '(｡•̀ᴗ-)✧' 'Good morning, commander! Shell warmed up and ready.' 'おはようございます！'
    elif (( h < 18 )); then __neo_say '(・ω・)ノ' 'Good afternoon! Everything is humming along nicely.' 'こんにちは！'
    else                    __neo_say '(´｡• ᵕ •｡`)' 'Good evening, commander. Quiet night in the shell so far.' 'こんばんは。'
    fi
}

# exit status → label + kaomoji for the prompt
__neo_status_label() {
    local st=$1
    case $st in
        1)   __neo_lbl=FAULT     __neo_kao='(・_・;)' ;;
        2)   __neo_lbl=MISUSE    __neo_kao='(￣ヘ￣;)' ;;
        126) __neo_lbl=DENIED    __neo_kao='(；一_一)' ;;
        127) __neo_lbl=NOT-FOUND __neo_kao='(・・;)ゞ' ;;
        129) __neo_lbl=SIGHUP    __neo_kao='(⊙_⊙;)' ;;
        130) __neo_lbl=SIGINT    __neo_kao='(¬_¬)' ;;
        131) __neo_lbl=SIGQUIT   __neo_kao='(°ロ°;)' ;;
        134) __neo_lbl=SIGABRT   __neo_kao='(×﹏×)' ;;
        137) __neo_lbl=SIGKILL   __neo_kao='(×﹏×)' ;;
        139) __neo_lbl=SIGSEGV   __neo_kao='(╥﹏╥)' ;;
        141) __neo_lbl=SIGPIPE   __neo_kao='(・へ・)' ;;
        143) __neo_lbl=SIGTERM   __neo_kao='(・_・;)' ;;
        148) __neo_lbl=STOPPED   __neo_kao='(˘ω˘)' ;;
        *)   __neo_lbl=FAULT     __neo_kao='(・_・;)' ;;
    esac
    (( __neo_utf8 )) || __neo_kao='(>_<)'
}

# ── git sensor ───────────────────────────────────────────────────────────────
# Branch is read straight from .git/HEAD (no fork). The dirty check runs git
# with fsmonitor and optional locks disabled, so a hostile repo config can't
# use the prompt to start a process, and it never writes to the index.
__neo_git() {
    __neo_gb= __neo_gs= __neo_gd=
    local d=$PWD gd line
    while :; do
        [[ -e $d/.git ]] && break
        [[ -z $d ]] && return 1
        d=${d%/*}
    done
    if [[ -f $d/.git ]]; then
        IFS= read -r line 2>/dev/null < "$d/.git" || return 1
        gd=${line#gitdir: }
        [[ $gd == /* ]] || gd=$d/$gd
    else
        gd=$d/.git
    fi
    [[ -r $gd/HEAD ]] || return 1
    IFS= read -r line < "$gd/HEAD" || return 1
    case $line in
        'ref: refs/heads/'*) __neo_gb=${line#ref: refs/heads/} ;;
        'ref: '*)            __neo_gb=${line#ref: } ;;
        *)                   __neo_gb=${line:0:7} ;;
    esac
    if   [[ -d $gd/rebase-merge || -d $gd/rebase-apply ]]; then __neo_gs=REBASE
    elif [[ -f $gd/MERGE_HEAD ]];       then __neo_gs=MERGE
    elif [[ -f $gd/CHERRY_PICK_HEAD ]]; then __neo_gs=PICK
    elif [[ -f $gd/BISECT_LOG ]];       then __neo_gs=BISECT
    fi
    if [[ ${__neo_cfg[git_dirty]} == on ]] && type -P git >/dev/null; then
        local out
        out=$(GIT_OPTIONAL_LOCKS=0 command git -c core.fsmonitor=false -c core.untrackedCache=false \
              --no-optional-locks status --porcelain=v1 --untracked-files=no --ignore-submodules=dirty 2>/dev/null) \
            || { __neo_gd=?; return 0; }
        [[ -n $out ]] && __neo_gd=1 || __neo_gd=0
    fi
    return 0
}

# ── prompt ───────────────────────────────────────────────────────────────────
declare -ga __neo_null=()
__neo_t0=
__neo_prompts=0

# append a coloured segment: __neo_seg COLOR TEXT
__neo_seg() {
    __neo_ps+=$'\001'"$1"$'\002'"$2"
    __neo_vis+=$2
}

__neo_fmt_dur() { # microseconds → $__neo_s
    local us=$1 s=$(( $1 / 1000000 ))
    if   (( s < 60 ));   then printf -v __neo_s '%d.%ds' "$s" $(( us / 100000 % 10 ))
    elif (( s < 3600 )); then printf -v __neo_s '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else                      printf -v __neo_s '%dh%02dm' $(( s / 3600 )) $(( s / 60 % 60 ))
    fi
}

__neo_precmd() {
    local st=$? pst=("${PIPESTATUS[@]}")
    local -n c=__neo_c g=__neo_g
    local R=${c[r]} cols=${COLUMNS:-80} dur=

    # runtime of the last command (PS0 stamped __neo_t0 just before it ran)
    if [[ -n $__neo_t0 && -n ${EPOCHREALTIME-} ]] && (( __neo_t0 > 1 )); then
        local now=${EPOCHREALTIME/[.,]/}
        (( now - __neo_t0 >= 10#${__neo_cfg[duration]} * 1000000 && 10#${__neo_cfg[duration]} > 0 )) && {
            __neo_fmt_dur $(( now - __neo_t0 )); dur=$__neo_s; }
    fi
    local ran=${__neo_t0:+1}
    __neo_t0=

    [[ ${__neo_cfg[prompt]} == on ]] || return "$st"

    # ── gather: identity · path · git · context · right side ──
    local idc=${c[a1]}
    (( EUID == 0 )) && idc=${c[crit]}
    __neo_clean "$__neo_user@${HOSTNAME%%.*}"; local who=$__neo_s
    (( EUID == 0 )) && who="${g[root]} $who"

    local p=$PWD
    if [[ -n ${HOME-} && $HOME != / && ( $p == "$HOME" || $p == "$HOME"/* ) ]]; then p="~${p#"$HOME"}"; fi
    local -a parts
    IFS=/ read -ra parts <<< "$p"
    local depth=$(( 10#${__neo_cfg[path_depth]} )) i pshort
    if (( ${#parts[@]} > depth + 1 )); then
        local full="${parts[0]}/${g[ell]}"
        for (( i = ${#parts[@]} - depth; i < ${#parts[@]}; i++ )); do full+="/${parts[i]}"; done
        p=$full
    fi
    __neo_clean "$p"; p=$__neo_s
    pshort=$p
    (( ${#parts[@]} > 2 )) && { __neo_clean "${g[ell]}/${parts[-1]}"; pshort=$__neo_s; }

    local br= gstate= gdirty=
    if [[ ${__neo_cfg[git]} == on ]] && __neo_git; then
        __neo_clean "$__neo_gb"; br=$__neo_s
        (( ${#br} > 32 )) && br="${br:0:31}${g[ell]}"
        gstate=$__neo_gs gdirty=$__neo_gd
    fi

    local ctx=
    if [[ -n ${VIRTUAL_ENV-} ]]; then
        local ve=${VIRTUAL_ENV_PROMPT:-${VIRTUAL_ENV##*/}}; ve=${ve#\(}; ve=${ve%\) }; ve=${ve%\)}
        ctx+=" ${g[venv]} $ve"
    fi
    [[ -n ${CONDA_DEFAULT_ENV-} && ${CONDA_DEFAULT_ENV} != base ]] && ctx+=" ${g[venv]} $CONDA_DEFAULT_ENV"
    # toolbox / distrobox / podman / docker
    [[ -f /run/.containerenv || -f /.dockerenv ]] && ctx+=" ${g[box]} ${CONTAINER_ID:-${__neo_box:-container}}"
    [[ -n ${SSH_CONNECTION-} ]] && ctx+=" ${g[ssh]} ssh"
    [[ -n $ctx ]] && { __neo_clean "$ctx"; ctx=$__neo_s; }
    local nj=0 j
    j=$(jobs -p 2>/dev/null) && [[ -n $j ]] && { local -a ja; mapfile -t ja <<< "$j"; nj=${#ja[@]}; }

    local fail=0 codes=$st sfull= sshort= tdur= tclock=
    if (( st != 0 && ran )); then
        fail=1
        __neo_status_label "$st"
        if (( ${#pst[@]} > 1 )); then printf -v codes '%s|' "${pst[@]}"; codes=${codes%|}; fi
        sfull=" ${g[fail]} $codes $__neo_lbl"
        [[ ${__neo_cfg[navigator]} == on ]] && sfull+=" $__neo_kao"
        sshort=" ${g[fail]} $st"
    fi
    [[ -n $dur ]] && tdur=" ${g[time]} $dur"
    if [[ ${__neo_cfg[clock]} == on ]]; then
        printf -v tclock '%(%H:%M:%S)T' -1
        tclock=" ${g[clock]:+${g[clock]} }$tclock"
    fi

    # ── fit to the terminal width ──
    # Shed detail step by step instead of wrapping: clock → status label →
    # duration, then shorter path → context → git/identity.
    local __neo_ps __neo_vis lvl tier rs rv lw rw fit=0
    local -a rtiers=("$sfull$tdur$tclock" "$sfull$tdur" "$sshort$tdur" "$sshort" "")
    for lvl in 0 1 2 3; do
        __neo_ps= __neo_vis=
        __neo_seg "${c[faint]}" "${g[tl]}"
        (( lvl < 3 )) && __neo_seg "${c[b]}$idc" "${g[lb]} $who ${g[rb]}"
        __neo_seg "$R${c[faint]}" "${g[fill]}${g[lp]} "
        if (( lvl == 0 )); then __neo_seg "$R${c[b]}" "$p"; else __neo_seg "$R${c[b]}" "$pshort"; fi
        __neo_seg "$R${c[faint]}" " ${g[rp]}"
        if [[ -n $br ]] && (( lvl < 3 )); then
            __neo_seg "${c[faint]}" "${g[fill]}${g[lp]} "
            __neo_seg "${c[a2]}" "${g[branch]} $br"
            [[ -n $gstate ]] && __neo_seg "${c[warn]}" " $gstate"
            case $gdirty in
                1) __neo_seg "${c[warn]}" " ${g[dirty]}" ;;
                0) __neo_seg "${c[ok]}" " ${g[clean]}" ;;
            esac
            __neo_seg "${c[faint]}" " ${g[rp]}"
        fi
        if [[ -n $ctx ]] && (( lvl < 2 )); then
            __neo_seg "${c[faint]}" "${g[fill]}${g[lp]}"
            __neo_seg "${c[a3]}" "$ctx"
            __neo_seg "${c[faint]}" " ${g[rp]}"
        fi
        if (( nj )); then
            __neo_seg "${c[faint]}" "${g[fill]}${g[lp]} "
            __neo_seg "${c[warn]}" "${g[jobs]} $nj"
            __neo_seg "${c[faint]}" " ${g[rp]}"
        fi
        __neo_width "$__neo_vis"; lw=$__neo_w
        for tier in 0 1 2 3 4; do
            rv=${rtiers[tier]}
            __neo_width "$rv"; rw=$__neo_w
            # a failed command's code outranks a long path: only drop it at the last level
            (( tier == 4 && ${#sshort} && lvl < 3 )) && continue
            (( lw + rw + 1 <= cols )) && { fit=1; break 2; }
        done
    done

    # right side, coloured per part
    rs=
    case $tier in
        0|1) [[ -n $sfull ]] && rs+=$'\001'"${c[b]}${c[crit]}"$'\002'"$sfull"$'\001'"$R"$'\002' ;;
        2|3) [[ -n $sshort ]] && rs+=$'\001'"${c[b]}${c[crit]}"$'\002'"$sshort"$'\001'"$R"$'\002' ;;
    esac
    (( tier <= 2 )) && [[ -n $tdur ]] && rs+=$'\001'"${c[warn]}"$'\002'"$tdur"
    (( tier == 0 )) && [[ -n $tclock ]] && rs+=$'\001'"${c[dim]}"$'\002'"$tclock"
    local fill=$(( cols - lw - rw - 1 )) line=
    (( fit )) || fill=0
    if (( fill > 0 )); then printf -v line '%*s' "$fill" ''; line=${line// /${g[fill]}}; fi
    __neo_seg "${c[faint]}" "$line"
    __neo_ps+="$rs"$'\001'"$R"$'\002'

    # ── line 2 ──
    local ac=${c[a1]}
    (( fail )) && ac=${c[crit]}
    local l2=$'\001'"${c[faint]}"$'\002'"${g[bl]}"$'\001'"${c[b]}$ac"$'\002'"${g[arrow]}"$'\001'"$R"$'\002 '

    # terminal title (sanitised); only for terminals known to support OSC 0
    local title=
    if [[ ${__neo_cfg[title]} == on && $TERM == @(xterm*|kitty*|alacritty*|foot*|wezterm*|ghostty*|tmux*|screen*|rxvt*|konsole*|vte*) ]]; then
        __neo_clean "neosh ${g[sep]} $who: $p"
        title=$'\001\e]0;'"$__neo_s"$'\a\002'
    fi

    local gap=
    [[ ${__neo_cfg[spacing]} == on ]] && (( __neo_prompts++ > 0 )) && gap=$'\n'
    __neo_ps1="$title$gap$__neo_ps"$'\n'"$l2"
    return "$st"
}

__neo_install_prompt() {
    [[ ${__neo_cfg[prompt]} == on ]] || return 0
    shopt -s promptvars
    export VIRTUAL_ENV_DISABLE_PROMPT=1   # the HUD shows the venv itself
    # PS1 only *references* variables. Bash doesn't re-expand the values of
    # expanded variables, so a directory named '$(rm -rf ~)' or '\u' is shown
    # literally and never runs.
    PS1='${__neo_ps1}'
    PS2='${__neo_ps2}'
    __neo_ps2=$'\001'"${__neo_c[faint]}"$'\002'"  ${__neo_g[cont]} "$'\001'"${__neo_c[r]}"$'\002'
    # PS0 is expanded right before each command runs. Assigning inside an array
    # subscript stamps the start time without starting a subshell.
    __neo_stamp='${__neo_null[__neo_t0=${EPOCHREALTIME/[.,]/}]}'
    [[ -n ${EPOCHREALTIME-} ]] || __neo_stamp='${__neo_null[__neo_t0=1]}'   # bash 4.4: no timing
    if [[ ${PS0-} != *"$__neo_stamp"* ]]; then PS0="$__neo_stamp${PS0-}"; fi
    # Run first in PROMPT_COMMAND so it sees the real $? / PIPESTATUS. Other
    # hooks (vte.sh, direnv, …) keep running after it, unchanged.
    if [[ ${PROMPT_COMMAND-} != __neo_precmd* ]]; then
        PROMPT_COMMAND="__neo_precmd${PROMPT_COMMAND:+$'\n'$PROMPT_COMMAND}"
    fi
}

# ── boot sequence ────────────────────────────────────────────────────────────
__neo_bootline() { # label status [colour]
    local label=$1 st=$2 col=${3:-${__neo_c[ok]}} dots
    __neo_width "$label"
    local n=$(( 38 - __neo_w )); (( n < 3 )) && n=3
    printf -v dots '%*s' "$n" ''; dots=${dots// /.}
    printf '   %s%s %s%s %s%s%s\n' "${__neo_c[dim]}" "$label" "${__neo_c[faint]}" "$dots" "${__neo_c[b]}$col" "$st" "${__neo_c[r]}"
    [[ ${__neo_cfg[boot]} == full ]] && command sleep 0.05 2>/dev/null
    return 0
}

__neo_boot() {
    local mode=${__neo_cfg[boot]}
    [[ $mode == off || ! -t 1 ]] && return 0
    local c=${__neo_c[a1]} m=${__neo_c[a2]} R=${__neo_c[r]} B=${__neo_c[b]} jp=
    (( __neo_utf8 )) && jp=" // 新殻インターフェース"
    local th=${__neo_cfg[theme]^^}
    (( __neo_utf8 )) && th+=" ${__neo_theme_jp[${__neo_cfg[theme]}]}"
    if [[ $mode == compact ]]; then
        printf ' %s%s%s %sNEOSH %s%s%s%s  %s%s bash %s %s theme %s%s\n' \
            "$m" "${__neo_g[hex]}" "$R" "$B$c" "$NEOSH_VERSION" "$R" "${__neo_c[dim]}" "$jp" \
            "${__neo_c[faint]}" "${__neo_g[sep]}" "${BASH_VERSION%%(*}" "${__neo_g[sep]}" "$th" "$R"
        __neo_greeting
        return 0
    fi
    printf '\n %s%s%s %sNEOSH SYSTEM v%s%s%s%s%s\n' "$m" "${__neo_g[hex]}" "$R" "$B$c" "$NEOSH_VERSION" "$R" "${__neo_c[dim]}" "$jp" "$R"
    __neo_bootline "bash ${BASH_VERSION%%(*} core" OK
    local hf=${HISTFILE:-~/.bash_history}; [[ $hf == "$HOME"/* ]] && hf="~${hf#"$HOME"}"
    (( ${#hf} > 24 )) && hf="${__neo_g[ell]}${hf: -23}"
    __neo_bootline "readline ${__neo_g[sep]} history $hf" OK
    if declare -F _comp_initialize >/dev/null || declare -F _init_completion >/dev/null; then
        __neo_bootline "bash-completion" OK
    else
        __neo_bootline "bash-completion" "--" "${__neo_c[dim]}"
    fi
    if [[ ${__neo_cfg[git]} == on ]] && type -P git >/dev/null; then __neo_bootline "git sensor" OK
    else __neo_bootline "git sensor" OFF "${__neo_c[dim]}"; fi
    local depth=256; (( __neo_depth == 24 )) && depth=truecolor; (( __neo_depth == 0 )) && depth=mono
    __neo_bootline "theme $th [$depth]" OK
    __neo_bootline "waking navigator KAGARI-AI" OK
    if (( __neo_utf8 )); then printf '   %s>> 起動完了 — all systems green%s\n' "$B${__neo_c[ok]}" "$R"
    else printf '   %s>> boot complete - all systems green%s\n' "$B${__neo_c[ok]}" "$R"; fi
    __neo_greeting
    printf '\n'
}

# ── the `neo` command deck ───────────────────────────────────────────────────
__neo_bar() { # pct width → $__neo_s (coloured bar)
    local pct=$1 w=${2:-20} n col=${__neo_c[a1]} on off
    (( n = pct * w / 100, n > w ? (n = w) : 0 ))
    (( pct >= 90 )) && col=${__neo_c[crit]}
    (( pct >= 75 && pct < 90 )) && col=${__neo_c[warn]}
    printf -v on '%*s' "$n" ''; printf -v off '%*s' $(( w - n )) ''
    __neo_s="$col${on// /${__neo_g[bar]}}${__neo_c[faint]}${off// /${__neo_g[bar0]}}${__neo_c[r]}"
}

__neo_panel() { # number EN JP
    local jp=; (( __neo_utf8 )) && jp=" $3"
    printf '\n %s%s %s%s %s%s%s%s\n' "${__neo_c[a2]}" "${__neo_g[lb]}" "${__neo_c[b]}${__neo_c[a1]}" "$1" "$2" "${__neo_c[r]}${__neo_c[dim]}" "$jp" "${__neo_c[r]}"
}

__neo_hb() { # KiB → $__neo_s human readable
    local k=$1
    if   (( k >= 1073741824 )); then printf -v __neo_s '%d.%dT' $(( k / 1073741824 )) $(( k * 10 / 1073741824 % 10 ))
    elif (( k >= 1048576 ));    then printf -v __neo_s '%d.%dG' $(( k / 1048576 )) $(( k * 10 / 1048576 % 10 ))
    elif (( k >= 1024 ));       then printf -v __neo_s '%dM' $(( k / 1024 ))
    else                             printf -v __neo_s '%dK' "$k"
    fi
}

__neo_status() {
    local D=${__neo_c[dim]} R=${__neo_c[r]} B=${__neo_c[b]} line k v
    local mood=ok kao='(｀・ω・´)ゞ' msg="All systems nominal on ${HOSTNAME%%.*}." jp='全システム正常です。'

    # 01 CORE
    __neo_panel 01 'CORE' '炉心'
    local l1 l5 l15 rest up cores=0
    read -r l1 l5 l15 rest 2>/dev/null < /proc/loadavg
    read -r up rest 2>/dev/null < /proc/uptime; up=${up%.*}
    while IFS= read -r line; do [[ $line == processor* ]] && (( cores++ )); done 2>/dev/null < /proc/cpuinfo
    (( cores )) || cores=1
    local upt
    if (( up >= 86400 )); then upt="$(( up / 86400 ))d $(( up / 3600 % 24 ))h"; else upt="$(( up / 3600 ))h $(( up / 60 % 60 ))m"; fi
    printf '   %sload%s %s %s %s  %s%s %d cores %s up %s%s\n' "$D" "$R" "$l1" "$l5" "$l15" "$D" "${__neo_g[sep]}" "$cores" "${__neo_g[sep]}" "$upt" "$R"
    local mt=0 ma=0 st=0 sf=0
    while IFS=': ' read -r k v rest; do
        case $k in MemTotal) mt=$v ;; MemAvailable) ma=$v ;; SwapTotal) st=$v ;; SwapFree) sf=$v ;; esac
    done 2>/dev/null < /proc/meminfo
    if (( mt )); then
        local mp=$(( (mt - ma) * 100 / mt ))
        __neo_bar "$mp" 24; local bar=$__neo_s
        __neo_hb $(( mt - ma )); local mu=$__neo_s; __neo_hb "$mt"
        printf '   %smem %s  %s %3d%%  %s%s / %s%s\n' "$D" "$R" "$bar" "$mp" "$D" "$mu" "$__neo_s" "$R"
        (( mp >= 90 )) && mood=warn kao='(・_・;)' msg="Memory's nearly full: $mp% used. Squeezy!" jp='メモリ残量わずか。'
        if (( st )); then
            local sp=$(( (st - sf) * 100 / st ))
            __neo_bar "$sp" 24; printf '   %sswap%s  %s %3d%%\n' "$D" "$R" "$__neo_s" "$sp"
        fi
    fi
    local lint=${l1%.*}
    if [[ $mood == ok ]] && (( ${lint:-0} >= cores * 2 )); then
        mood=warn kao='(ﾟДﾟ;)' msg="Load $l1 on $cores cores! Every core is giving it everything!" jp='全コア全力稼働中！'
    fi

    # 02 THERMAL
    local f hot=-1 hotname= name lbl t
    for f in /sys/class/hwmon/hwmon*/temp*_input; do
        [[ -r $f ]] || continue
        read -r t 2>/dev/null < "$f" || continue
        [[ $t =~ ^-?[0-9]+$ ]] || continue
        (( t /= 1000 ))
        if (( t > hot && t < 150 )); then
            hot=$t; name=
            read -r name 2>/dev/null < "${f%/*}/name"
            lbl=; [[ -r ${f%_input}_label ]] && read -r lbl 2>/dev/null < "${f%_input}_label"
            __neo_clean "$name${lbl:+ $lbl}"; hotname=$__neo_s
        fi
    done
    if (( hot >= 0 )); then
        __neo_panel 02 'THERMAL' '熱源'
        local tc=${__neo_c[ok]}
        (( hot >= 75 )) && tc=${__neo_c[warn]}
        (( hot >= 90 )) && tc=${__neo_c[crit]}
        printf '   %shottest%s %s%d°C%s  %s%s%s\n' "$D" "$R" "$B$tc" "$hot" "$R" "$D" "$hotname" "$R"
        if (( hot >= 90 )); then mood=crit kao='(×﹏×)' msg="Commander!! $hotname is at ${hot}°C. The hearth is overheating!" jp='熱暴走の危険！'
        elif (( hot >= 80 )) && [[ $mood == ok ]]; then mood=warn kao='(°ロ°;)' msg="$hotname is running toasty at ${hot}°C. I'll keep watch~" jp='温度上昇中。'
        fi
    fi

    # 03 STORAGE
    __neo_panel 03 'STORAGE' '記憶域'
    local -A seen=()
    local fs size used avail pct mnt
    while read -r fs size used avail pct mnt; do
        [[ $fs == Filesystem ]] && continue
        [[ -n ${seen[$fs]-} ]] && continue; seen[$fs]=1
        pct=${pct%\%}
        __neo_bar "$pct" 24; local bar=$__neo_s
        __neo_hb "$avail"; local free=$__neo_s; __neo_clean "$mnt"
        printf '   %-10s %s %3d%%  %s%s free%s\n' "$__neo_s" "$bar" "$pct" "$D" "$free" "$R"
        if (( pct >= 95 )) && [[ $mood != crit ]]; then mood=warn kao='(・・;)ゞ' msg="$mnt is $pct% full! Time for some spring cleaning~" jp='空き容量がほとんどありません。'; fi
    done < <(LC_ALL=C command df -Pk / "$HOME" 2>/dev/null)

    # 04 NETWORK
    if type -P ip >/dev/null; then
        local dev= ifn fam addr
        read -r _ _ _ _ dev _ < <(command ip -4 route show default 2>/dev/null)
        local any=0
        while read -r _ ifn fam addr _; do
            [[ $ifn == @(lo|docker*|br-*|veth*|virbr*|podman*|cni*|flannel*) ]] && continue
            (( any++ )) || __neo_panel 04 'NETWORK' '通信'
            __neo_clean "$ifn"
            if [[ $ifn == "$dev" ]]; then printf '   %s%-15s%s %s  %s(default route)%s\n' "${__neo_c[a1]}" "$__neo_s" "$R" "${addr%/*}" "$D" "$R"
            else printf '   %-15s %s\n' "$__neo_s" "${addr%/*}"; fi
        done < <(command ip -o -4 addr show 2>/dev/null)
    fi

    # 05 SHELL
    __neo_panel 05 'SHELL' '殻'
    local hn=0
    [[ -r ${HISTFILE-} ]] && { local -a hl; mapfile -t hl < "$HISTFILE"; hn=${#hl[@]}; }
    printf '   %sbash%s %s %s%s pid %d %s depth %d %s %d history lines %s theme %s%s\n' "$D" "$R" "${BASH_VERSION%%(*}" "$D" "${__neo_g[sep]}" "$$" "${__neo_g[sep]}" "${SHLVL:-1}" "${__neo_g[sep]}" "$hn" "${__neo_g[sep]}" "${__neo_cfg[theme]}" "$R"
    printf '\n'
    local nav=${__neo_cfg[navigator]}; __neo_cfg[navigator]=on
    __neo_say "$kao" "$msg" "$jp"
    __neo_cfg[navigator]=$nav
}

__neo_themes() {
    local t a b c rgb
    for t in "${__neo_theme_order[@]}"; do
        read -ra rgb <<< "${__neo_theme_rgb[$t]}"
        __neo_sgr "${rgb[0]}"; a=$__neo_esc; __neo_sgr "${rgb[1]}"; b=$__neo_esc; __neo_sgr "${rgb[2]}"; c=$__neo_esc
        local mark=' '; [[ $t == "${__neo_cfg[theme]}" ]] && mark=${__neo_g[arrow]}
        local jp=; (( __neo_utf8 )) && jp=${__neo_theme_jp[$t]}
        printf ' %s %s██%s██%s██%s  %-8s %s%s%s\n' "$mark" "$a" "$b" "$c" "${__neo_c[r]}" "${t^^}" "${__neo_c[dim]}" "$jp" "${__neo_c[r]}"
    done
}

__neo_help() {
    local A=${__neo_c[a1]} M=${__neo_c[a2]} D=${__neo_c[dim]} R=${__neo_c[r]} B=${__neo_c[b]} jp=
    (( __neo_utf8 )) && jp=" 指令盤"
    printf '\n %s%s%s %sNEOSH COMMAND DECK%s%s%s\n\n' "$M" "${__neo_g[hex]}" "$R" "$B$A" "$R$D" "$jp" "$R"
    local row
    while IFS=';' read -r a b; do
        printf '   %s%-26s%s %s\n' "$A" "$a" "$R" "$b"
    done <<'EOF'
neo status;system HUD: core, thermal, storage, network, shell
neo theme [NAME];list themes or switch (saved)
neo boot full|compact|off;startup banner style
neo set KEY VALUE;change a setting (see `neo config`)
neo config;show settings and the config file
neo reload;reload neosh in this shell
neo nav;ask KAGARI how things are
neo off;plain bash prompt for this session
neo version;version info
neo uninstall;remove neosh, back to plain bash
EOF
    printf '\n   %sOne plain-bash session: NEOSH_DISABLE=1 bash%s\n\n' "$D" "$R"
}

__neo_refresh() {
    __neo_detect; __neo_palette; __neo_glyphset
    __neo_ps2=$'\001'"${__neo_c[faint]}"$'\002'"  ${__neo_g[cont]} "$'\001'"${__neo_c[r]}"$'\002'
}

neo() {
    local cmd=${1-help}; shift 2>/dev/null
    case $cmd in
        help|-h|--help) __neo_help ;;
        status|hud) __neo_status ;;
        theme|themes)
            if [[ -z ${1-} ]]; then __neo_themes; return; fi
            local t=${1,,}
            __neo_cfg_save theme "$t" || { printf 'neosh: themes: %s\n' "${__neo_theme_order[*]}" >&2; return 1; }
            __neo_refresh
            __neo_say '(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧' "Theme switched to ${t^^}!" "${__neo_theme_jp[$t]}" ;;
        boot)
            [[ -n ${1-} ]] || { printf 'boot=%s\n' "${__neo_cfg[boot]}"; return; }
            __neo_cfg_save boot "$1" && printf 'boot=%s\n' "$1" ;;
        set)
            [[ $# -eq 2 ]] || { printf 'usage: neo set KEY VALUE\n' >&2; return 2; }
            [[ -n ${__neo_cfg[$1]+x} ]] || { printf 'neosh: unknown key: %s\n' "$1" >&2; return 1; }
            __neo_cfg_save "$1" "$2" || return 1
            __neo_refresh
            if [[ $1 == prompt ]]; then printf 'neosh: open a new shell (or `neo reload`) to apply prompt=%s\n' "$2"; fi ;;
        config|conf)
            printf '%s# %s%s\n' "${__neo_c[dim]}" "$NEOSH_CONFIG" "${__neo_c[r]}"
            local k; for k in theme boot color glyphs prompt navigator clock git git_dirty title spacing duration path_depth; do
                printf '%-11s = %s\n' "$k" "${__neo_cfg[$k]}"
            done ;;
        reload)
            unset __NEOSH_LOADED
            # shellcheck source=/dev/null
            . "$NEOSH_HOME/neosh.bash" ;;
        nav)
            __neo_greeting ;;
        off)
            PROMPT_COMMAND=${PROMPT_COMMAND#__neo_precmd}; PROMPT_COMMAND=${PROMPT_COMMAND#$'\n'}
            PS0=${PS0//"$__neo_stamp"/}
            PS1=${__neo_orig_ps1-'\s-\v\$ '} PS2=${__neo_orig_ps2-'> '}
            __neo_say '(・へ・)' 'Prompt handed back to plain bash for this session. `neo reload` to bring me back.' ;;
        version|-v|--version)
            printf 'neosh %s on bash %s (%s)\n' "$NEOSH_VERSION" "$BASH_VERSION" "$NEOSH_HOME" ;;
        uninstall)
            if [[ -x $NEOSH_HOME/uninstall.sh ]]; then "$NEOSH_HOME/uninstall.sh" "$@"
            else printf 'neosh: uninstaller not found in %s\n' "$NEOSH_HOME" >&2; return 1; fi ;;
        *) printf 'neosh: unknown command: %s (try `neo help`)\n' "$cmd" >&2; return 2 ;;
    esac
}

__neo_complete() {
    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
    if (( COMP_CWORD == 1 )); then
        mapfile -t COMPREPLY < <(compgen -W 'help status theme boot set config reload nav off version uninstall' -- "$cur")
    elif (( COMP_CWORD == 2 )); then
        case $prev in
            theme) mapfile -t COMPREPLY < <(compgen -W "${__neo_theme_order[*]}" -- "$cur") ;;
            boot)  mapfile -t COMPREPLY < <(compgen -W 'full compact off' -- "$cur") ;;
            set)   mapfile -t COMPREPLY < <(compgen -W "${!__neo_cfg[*]}" -- "$cur") ;;
        esac
    elif (( COMP_CWORD == 3 )) && [[ ${COMP_WORDS[1]} == set ]]; then
        local opts
        case $prev in
            theme) opts="${__neo_theme_order[*]}" ;;
            boot) opts='full compact off' ;;
            color) opts='auto truecolor 256 off' ;;
            glyphs) opts='auto unicode ascii' ;;
            duration|path_depth) opts= ;;
            *) opts='on off' ;;
        esac
        mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
    fi
}

# Used by install.sh to verify the runtime loads and renders in this bash.
__neo_selftest() {
    declare -F neo __neo_precmd >/dev/null || return 1
    __neo_precmd || true
    [[ -n $__neo_ps1 ]] || return 1
    return 0
}

# ── activate ────────────────────────────────────────────────────────────────
if [[ ${PS1-} != '${__neo_ps1}' ]]; then __neo_orig_ps1=${PS1-} __neo_orig_ps2=${PS2-}; fi
# container name for the HUD (toolbox / podman write it to /run/.containerenv)
if [[ -r /run/.containerenv ]]; then
    while IFS= read -r __neo_l; do
        [[ $__neo_l == name=* ]] && { __neo_box=${__neo_l#name=}; __neo_box=${__neo_box//\"/}; break; }
    done < /run/.containerenv
    unset __neo_l
fi
__neo_user=${USER:-$(id -un 2>/dev/null || printf '%s' "$EUID")}
__neo_cfg_load
__neo_refresh
shopt -s checkwinsize histappend
complete -F __neo_complete neo
if ! declare -F command_not_found_handle >/dev/null; then
    # only when the distro didn't install one (Fedora's PackageKit hook is kept)
    command_not_found_handle() {
        __neo_clean "$1"
        if [[ ${__neo_cfg[navigator]} == on ]]; then
            __neo_say '(・・;)ゞ' "\"$__neo_s\" isn't a command I know, commander." 'コマンドが見つかりません。' >&2
        else
            printf 'bash: %s: command not found\n' "$__neo_s" >&2
        fi
        return 127
    }
fi
__neo_install_prompt
__neo_boot
