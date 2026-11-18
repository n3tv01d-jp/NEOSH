#!/usr/bin/env bash
# neosh test suite: every case runs in a throwaway $HOME, so your real
# ~/.bashrc is never touched.   Usage: tests/run.sh
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/neosh-test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
pass=0 fail=0

ok()   { printf '  \e[38;2;93;255;158m✓\e[0m %s\n' "$1"; (( pass++ )); }
bad()  { printf '  \e[38;2;255;59;92m✖ %s\e[0m\n' "$1"; (( fail++ )); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# run a command with a clean environment rooted at sandbox $H
sb() { local H=$1; shift; env -i HOME="$H" PATH="/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 TERM=dumb USER="${USER:-test}" "$@"; }
newhome() { local H; H=$(mktemp -d "$WORK/home.XXXXXX"); printf '%s' "$H"; }
hooks() { grep -cxF '# >>> neosh >>>' "$1" 2>/dev/null || true; }

sample_rc() {
    cat <<'EOF'
# .bashrc
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi
export EDITOR=vim
alias ll='ls -l'
EOF
}

echo "── syntax"
for f in install.sh uninstall.sh update.sh lib/neosh.bash lib/neoshrc tests/run.sh; do
    check "bash -n $f" bash -n "$ROOT/$f"
done

echo "── round trip: existing ~/.bashrc"
H=$(newhome); sample_rc > "$H/.bashrc"; cp "$H/.bashrc" "$WORK/orig"
sb "$H" "$ROOT/install.sh" >/dev/null 2>&1; check "install exits 0" test $? -eq 0
check "hook added once" test "$(hooks "$H/.bashrc")" -eq 1
check "original lines kept" grep -qxF "alias ll='ls -l'" "$H/.bashrc"
check "backup created" bash -c 'compgen -G "$1/.bashrc.neosh-backup.*" >/dev/null' _ "$H"
check "backup equals original" bash -c 'cmp -s "$2" "$1"/.bashrc.neosh-backup.*' _ "$H" "$WORK/orig"
check "launcher executable" test -x "$H/.local/bin/neosh"
check "config created" test -f "$H/.config/neosh/neosh.conf"
sb "$H" "$ROOT/install.sh" >/dev/null 2>&1
check "re-install keeps a single hook" test "$(hooks "$H/.bashrc")" -eq 1
check "re-install makes no extra backup" test "$(compgen -G "$H/.bashrc.neosh-backup.*" | wc -l)" -eq 1

echo "── loading rules"
out=$(sb "$H" bash -i -c 'declare -F neo >/dev/null && echo LOADED' 2>/dev/null </dev/null)
check "interactive bash loads neosh" test "$out" = LOADED
out=$(sb "$H" bash -c 'declare -F neo >/dev/null && echo LOADED; echo done' 2>/dev/null </dev/null)
check "non-interactive bash -c is untouched" test "$out" = done
out=$(sb "$H" NEOSH_DISABLE=1 bash -i -c 'declare -F neo >/dev/null && echo LOADED; echo plain' 2>/dev/null </dev/null)
check "NEOSH_DISABLE=1 gives plain bash" test "$out" = plain
out=$(sb "$H" "$H/.local/bin/neosh" -c 'echo "$((6*7))"' 2>/dev/null)
check "launcher with args behaves like bash" test "$out" = 42
out=$(sb "$H" bash -i -c 'neo theme sakura >/dev/null; neo config' 2>/dev/null </dev/null)
check "neo theme persists" grep -q 'sakura' "$H/.config/neosh/neosh.conf"

echo "── hostile input"
cat > "$H/.config/neosh/neosh.conf" <<EOF
theme=\$(touch $WORK/CONFPWN)
boot=\`touch $WORK/CONFPWN\`
color=off; touch $WORK/CONFPWN
EOF
sb "$H" bash -i -c 'true' >/dev/null 2>&1 </dev/null
check "config values are never executed" test ! -e "$WORK/CONFPWN"
mkdir -p "$H/repo/.git" "$H/\$(touch $WORK" 2>/dev/null
printf 'ref: refs/heads/$(touch %s/GITPWN)`touch %s/GITPWN`\n' "$WORK" "$WORK" > "$H/repo/.git/HEAD"
sb "$H" bash -i -c 'cd ~/repo && __neo_precmd && printf "%s" "${PS1@P}" >/dev/null' >/dev/null 2>&1 </dev/null
check "branch name is never executed" test ! -e "$WORK/GITPWN"
d="$H/x\$(touch $WORK/DIRPWN)\`touch $WORK/DIRPWN\`"
mkdir -p "$d" 2>/dev/null
sb "$H" D="$d" bash -i -c 'cd "$D" && __neo_precmd && printf "%s" "${PS1@P}" >/dev/null' >/dev/null 2>&1 </dev/null
check "directory name is never executed" test ! -e "$WORK/DIRPWN"
esc=$(sb "$H" bash -i -c 'mkdir -p ~/$'"'"'e\e]0;HACK\a'"'"' && cd ~/$'"'"'e\e]0;HACK\a'"'"' && __neo_precmd && printf "%s" "$__neo_ps1"' 2>/dev/null </dev/null)
check "escape sequences in paths are stripped" bash -c '[[ $1 == *HACK* && $1 != *$'"'"'\e'"'"'* ]]' _ "$esc"

echo "── custom themes"
cat > "$H/.config/neosh/neosh.conf" <<CONF
theme=neon
theme.neon = #ff00aa #00ffcc #ffee00   # three colours, dim/faint derived
theme.full = 101010 202020 303030 404040 505050
theme.hearth = #000000 #000000 #000000
theme.evil = #000000 \$(touch $WORK/THEMEPWN) #000000
theme.\$(touch $WORK/THEMEPWN) = #000000 #000000 #000000
CONF
out=$(sb "$H" bash -i -c 'neo config' 2>/dev/null </dev/null)
check "theme= can name a custom theme" grep -qx 'theme       = neon' <<< "$out"
out=$(sb "$H" bash -i -c 'printf "%s|" "${__neo_theme_order[@]}"; printf "%s" "${__neo_theme_rgb[full]}"' 2>/dev/null </dev/null)
check "custom themes listed after the built-ins" grep -q '|specter|neon|full|16,16,16 32,32,32' <<< "$out"
check "a built-in can't be redefined" bash -c '[[ $1 != *"|hearth|"*"|hearth|"* ]]' _ "$out"
check "theme lines are never executed" test ! -e "$WORK/THEMEPWN"
sb "$H" bash -i -c 'neo theme add Mine "#112233" "#445566" "#778899" "#aabbcc" "#ddeeff"; neo theme mine' >/dev/null 2>&1 </dev/null
check "neo theme add saves the theme" grep -qx 'theme.mine = #112233 #445566 #778899 #aabbcc #ddeeff' "$H/.config/neosh/neosh.conf"
check "a saved custom theme can be selected" grep -qx 'theme=mine' "$H/.config/neosh/neosh.conf"
sb "$H" bash -i -c 'neo theme add bad "#12345" "#445566" "#778899"; neo theme add sakura "#111111" "#222222" "#333333"' >/dev/null 2>&1 </dev/null
check "bad colours and taken names are refused" bash -c '! grep -q "theme\.\(bad\|sakura\)" "$1"' _ "$H/.config/neosh/neosh.conf"
sb "$H" bash -i -c 'neo theme rm mine' >/dev/null 2>&1 </dev/null
check "neo theme rm deletes it" bash -c '! grep -q "theme\.mine" "$1"' _ "$H/.config/neosh/neosh.conf"
check "removing the active theme falls back to hearth" grep -qx 'theme=hearth' "$H/.config/neosh/neosh.conf"
out=$(sb "$H" bash -i -c 'neo preview' 2>/dev/null </dev/null)
check "neo preview draws every theme" bash -c 'for t in HEARTH REDLINE MECHA SAKURA ECLIPSE KURENAI ABYSS AURUM SPECTER NEON FULL; do [[ $1 == *"$t"* ]] || exit 1; done' _ "$out"
check "neo preview strips readline markers" bash -c '[[ $1 != *[$'"'"'\001\002'"'"']* ]]' _ "$out"
out=$(sb "$H" bash -i -c 'neo preview nope' 2>&1 </dev/null)
check "neo preview rejects unknown themes" grep -q 'unknown theme' <<< "$out"

echo "── nested shells (SHLVL)"
out=$(sb "$H" SHLVL=3 bash -i -c '__neo_precmd; printf "%s" "$__neo_ps1"' 2>/dev/null </dev/null)
check "nested shell shows its depth" grep -q '↳ 4' <<< "$out"
out=$(sb "$H" SHLVL=0 bash -i -c '__neo_precmd; printf "%s" "$__neo_ps1"' 2>/dev/null </dev/null)
check "top-level shell shows no depth" bash -c '[[ $1 != *↳* ]]' _ "$out"
out=$(sb "$H" SHLVL=3 bash -i -c 'neo set shlvl off; __neo_precmd; printf "%s" "$__neo_ps1"' 2>/dev/null </dev/null)
check "shlvl=off hides it" bash -c '[[ $1 != *↳* ]]' _ "$out"
sb "$H" bash -i -c 'neo set shlvl on' >/dev/null 2>&1 </dev/null

echo "── KAGARI's remarks"
fails='for i in 1 2 3; do __neo_t0=1; false; __neo_precmd; done'
out=$(sb "$H" TZ=UTC bash -i -c "$fails"'; __neo_t0=1; true; __neo_precmd' 2>/dev/null </dev/null)
check "three failures in a row get a remark" grep -q 'Three misses in a row' <<< "$out"
check "the streak ending gets a cheer" grep -q 'Back on track after 3 misses' <<< "$out"
out=$(sb "$H" TZ=UTC bash -i -c 'for i in 1 2; do __neo_t0=1; false; __neo_precmd; done; __neo_t0=1; (exit 130); __neo_precmd' 2>/dev/null </dev/null)
check "Ctrl-C doesn't count as a miss" bash -c '[[ $1 != *Three* ]]' _ "$out"
# a POSIX TZ that makes it 03:xx local time right now
h=$(date -u +%H); off=$(( 10#$h - 3 )); (( off > 12 )) && off=$(( off - 24 )); (( off < -12 )) && off=$(( off + 24 ))
out=$(sb "$H" TZ="NEO$off" bash -i -c '__neo_late=0; for i in 1 2; do __neo_t0=1; true; __neo_precmd; done' 2>/dev/null </dev/null)
check "after 02:00 KAGARI suggests bed, once" test "$(grep -c 'KAGARI' <<< "$out")" -eq 1
out=$(sb "$H" TZ="NEO$off" bash -i -c 'neo set quips off >/dev/null; __neo_late=0; __neo_t0=1; true; __neo_precmd; '"$fails" 2>/dev/null </dev/null)
check "quips=off keeps her quiet" bash -c '[[ $1 != *KAGARI* ]]' _ "$out"
sb "$H" bash -i -c 'neo set quips on' >/dev/null 2>&1 </dev/null

echo "── transient prompt (in a pseudo-terminal)"
if command -v python3 >/dev/null; then
    printf 'boot=off\ntransient=on\nclock=off\n' > "$H/.config/neosh/neosh.conf"
    out=$(sb "$H" python3 -I -c '
import os, pty, time, select, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-i"])
def rd(t):
    b = b""; end = time.time() + t
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try: b += os.read(fd, 65536)
            except OSError: break
    return b
rd(1.5); os.write(fd, b"echo hi\r"); out = rd(1.0)
os.write(fd, b"\r"); out2 = rd(1.0); os.write(fd, b"exit\r"); rd(0.3)
sys.stdout.write(repr(out) + "\n" + repr(out2))
' 2>/dev/null </dev/null)
    check "Enter collapses the HUD to one line" grep -qF '\x1b[2A\r\x1b[J\xe2\x96\xb6 echo hi' <<< "${out%%$'\n'*}"
    check "an empty Enter collapses it too" grep -qF '\x1b[2A\r\x1b[J\xe2\x96\xb6 ' <<< "${out#*$'\n'}"
    printf 'boot=off\n' > "$H/.config/neosh/neosh.conf"
else
    echo "  - skipped (needs python3 for a pty)"
fi

echo "── uninstall"
check "manifest records the checkout" grep -qx "source=$ROOT" "$H/.local/share/neosh/install.manifest"
sb "$H" "$H/.local/share/neosh/uninstall.sh" -y >/dev/null 2>&1; check "uninstall exits 0" test $? -eq 0
check "~/.bashrc restored byte-for-byte" cmp -s "$H/.bashrc" "$WORK/orig"
check "launcher removed" test ! -e "$H/.local/bin/neosh"
check "runtime removed" test ! -e "$H/.local/share/neosh"
check "config kept without --purge" test -d "$H/.config/neosh"
out=$(sb "$H" bash -i -c 'declare -F neo >/dev/null && echo LOADED; echo plain' 2>/dev/null </dev/null)
check "new shells are plain bash again" test "$out" = plain

echo "── user edits after install survive uninstall"
H=$(newhome); sample_rc > "$H/.bashrc"
sb "$H" "$ROOT/install.sh" >/dev/null 2>&1
echo 'export AFTER=1' >> "$H/.bashrc"
sb "$H" "$ROOT/uninstall.sh" -y --purge >/dev/null 2>&1
check "line added after the hook kept" grep -qxF 'export AFTER=1' "$H/.bashrc"
check "hook gone" test "$(hooks "$H/.bashrc")" -eq 0
check "--purge removes config" test ! -e "$H/.config/neosh"
check "--purge removes backup" test -z "$(compgen -G "$H/.bashrc.neosh-backup.*")"

echo "── symlinked ~/.bashrc (dotfile managers)"
H=$(newhome); mkdir -p "$H/dotfiles"; sample_rc > "$H/dotfiles/bashrc"; cp "$H/dotfiles/bashrc" "$WORK/orig2"
ln -s dotfiles/bashrc "$H/.bashrc"
sb "$H" "$ROOT/install.sh" >/dev/null 2>&1
check "symlink preserved" test -L "$H/.bashrc"
check "hook written to the link target" test "$(hooks "$H/dotfiles/bashrc")" -eq 1
sb "$H" "$ROOT/uninstall.sh" -y >/dev/null 2>&1
check "symlink still preserved" test -L "$H/.bashrc"
check "target restored" cmp -s "$H/dotfiles/bashrc" "$WORK/orig2"

echo "── no ~/.bashrc at all"
H=$(newhome)
sb "$H" "$ROOT/install.sh" >/dev/null 2>&1
check "~/.bashrc created with hook" test "$(hooks "$H/.bashrc")" -eq 1
sb "$H" "$ROOT/uninstall.sh" -y >/dev/null 2>&1
check "created ~/.bashrc removed again" test ! -e "$H/.bashrc"

echo "── --no-hook"
H=$(newhome); sample_rc > "$H/.bashrc"; cp "$H/.bashrc" "$WORK/orig3"
sb "$H" "$ROOT/install.sh" --no-hook >/dev/null 2>&1
check "~/.bashrc untouched" cmp -s "$H/.bashrc" "$WORK/orig3"
out=$(sb "$H" bash -c 'printf "declare -F neo >/dev/null && echo LOADED\nexit\n" | "$HOME/.local/bin/neosh" 2>/dev/null' </dev/null)
check "neosh launcher loads the layer" bash -c '[[ $1 == *LOADED* ]]' _ "$out"
sb "$H" "$ROOT/uninstall.sh" -y >/dev/null 2>&1

echo "── refusals"
H=$(newhome); mkdir -p "$H/.local/share/neosh"; echo keep > "$H/.local/share/neosh/precious"
sb "$H" "$ROOT/install.sh" >/dev/null 2>&1
check "won't overwrite a foreign ~/.local/share/neosh" test -f "$H/.local/share/neosh/precious"
check "bad --theme rejected" bash -c '! env -i HOME="$1" PATH=/usr/bin:/bin "$2/install.sh" --theme nope >/dev/null 2>&1' _ "$(newhome)" "$ROOT"

echo "── update.sh"
UPS=$WORK/upstream CO=$WORK/checkout
mkdir -p "$UPS"
(cd "$ROOT" && tar cf - --exclude=.git .) | tar xf - -C "$UPS"
gitq() { git -c user.name=neosh-test -c user.email=test@invalid -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
bump() { echo "$1" > "$UPS/VERSION"; gitq -C "$UPS" commit -qam "release $1"; }
gitq init -q "$UPS" && gitq -C "$UPS" add -A && gitq -C "$UPS" commit -qm v1 && gitq clone -q "$UPS" "$CO"
H=$(newhome); sample_rc > "$H/.bashrc"
sb "$H" "$CO/update.sh" >/dev/null 2>&1; check "refuses when neosh isn't installed" test $? -ne 0
sb "$H" "$CO/install.sh" >/dev/null 2>&1
sb "$H" bash -i -c 'neo theme add mine "#112233" "#445566" "#778899"; neo theme mine; neo set clock off' >/dev/null 2>&1 </dev/null
bump 9.9.9
sb "$H" "$CO/update.sh" >/dev/null 2>&1; check "update exits 0" test $? -eq 0
check "without --pull nothing is pulled" bash -c '! grep -qx 9.9.9 "$1/VERSION"' _ "$CO"
echo '# local tweak' >> "$CO/lib/neosh.bash"
sb "$H" "$CO/update.sh" >/dev/null 2>&1
check "without --pull local edits are installed" cmp -s "$CO/lib/neosh.bash" "$H/.local/share/neosh/neosh.bash"
gitq -C "$CO" checkout lib/neosh.bash
sb "$H" "$CO/update.sh" --pull >/dev/null 2>&1; check "update --pull exits 0" test $? -eq 0
check "--pull pulled and installed the new version" grep -qx 9.9.9 "$H/.local/share/neosh/VERSION"
check "still a single hook" test "$(hooks "$H/.bashrc")" -eq 1
check "no extra ~/.bashrc backup" test "$(compgen -G "$H/.bashrc.neosh-backup.*" | wc -l)" -eq 1
check "settings kept" grep -qx 'clock=off' "$H/.config/neosh/neosh.conf"
check "custom theme kept" grep -q '^theme.mine = ' "$H/.config/neosh/neosh.conf"
out=$(sb "$H" "$CO/update.sh" 2>&1)
check "second run: already up to date" grep -q 'already on the newest' <<< "$out"
bump 9.9.10
out=$(sb "$H" bash -i -c 'neo update --pull >/dev/null 2>&1; printf "%s" "$NEOSH_VERSION"' 2>/dev/null </dev/null)
check "neo update --pull updates and reloads the shell" test "$out" = 9.9.10
echo local >> "$CO/README.md"; bump 9.9.11
sb "$H" "$CO/update.sh" --pull >/dev/null 2>&1; check "refuses to pull over local changes" test $? -ne 0
check "a refused update changes nothing" grep -qx 9.9.10 "$H/.local/share/neosh/VERSION"
gitq -C "$CO" checkout README.md
H=$(newhome); sample_rc > "$H/.bashrc"; cp "$H/.bashrc" "$WORK/orig4"
sb "$H" "$CO/install.sh" --no-hook >/dev/null 2>&1
bump 9.9.12
sb "$H" "$CO/update.sh" --pull >/dev/null 2>&1
check "--no-hook install stays hook-free" cmp -s "$H/.bashrc" "$WORK/orig4"
check "--no-hook install updated" grep -qx 9.9.12 "$H/.local/share/neosh/VERSION"
H=$(newhome); sb "$H" "$ROOT/install.sh" --no-hook >/dev/null 2>&1
mkdir -p "$WORK/plain"; (cd "$ROOT" && tar cf - --exclude=.git .) | tar xf - -C "$WORK/plain"
sb "$H" "$WORK/plain/update.sh" --pull >/dev/null 2>&1; check "--pull outside a git checkout is an error" test $? -ne 0
sb "$H" "$WORK/plain/update.sh" >/dev/null 2>&1; check "without --pull it works without git" test $? -eq 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
