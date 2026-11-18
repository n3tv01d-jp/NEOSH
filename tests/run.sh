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
for f in install.sh uninstall.sh lib/neosh.bash lib/neoshrc tests/run.sh; do
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
esc=$(sb "$H" bash -i -c 'mkdir -p ~/$'"'"'e\e]0;HACK\a'"'"' && cd ~/$'"'"'e\e]0;HACK\a'"'"' && __neo_precmd && printf "%s" "$__neo_vis"' 2>/dev/null </dev/null)
check "escape sequences in paths are stripped" bash -c '[[ $1 != *$'"'"'\e'"'"'* ]]' _ "$esc"

echo "── uninstall"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
