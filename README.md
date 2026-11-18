<p align="center">
  <img src="assets/neosh.svg" alt="NEOSH banner" width="100%">
</p>

# NEOSH // 新殻インターフェース

A sci-fi anime-styled HUD for your bash shell, in the style of [HEARTH](../hearth). It runs on top of your normal bash and `~/.bashrc`, so everything you already use keeps working. You get a two-line status prompt, nine colour themes, a boot log, a system readout and KAGARI, the kaomoji navigator, commenting on what happens.

```
 ⬡ NEOSH 1.0.1 // 新殻インターフェース  · bash 5.3.0 · theme HEARTH 炉心
 (｡•̀ᴗ-)✧ KAGARI » Good morning, commander! Shell warmed up and ready.  おはようございます！

╭─◢ n3tvoid@hypr ◣─⟨ ~/githubprojects/hearth ⟩─⟨ ⎇ main ● ⟩──────── ✖ 127 NOT-FOUND (・・;)ゞ ⏱ 4.2s 炉 18:11:36
╰─▶ 
```

| Prompt segment | What it shows |
|---|---|
| `◢ user@host ◣` | Who and where you are. Turns red with `⚠` as root. |
| `⟨ path ⟩` | Working directory with `~` for home. Long paths are shortened to the last few folders (`path_depth`). |
| `⟨ ⎇ branch ● ⟩` | Git branch, plus `● dirty` / `✓ clean`. Shows `REBASE`, `MERGE`, `PICK` or `BISECT` while one is in progress. |
| `⟨ ⌬ venv ⬢ toolbox ⇄ ssh ↳ 2 ⟩` | Python venv / conda env, toolbox / distrobox / podman / docker container, SSH session, and `↳ N` when this shell is nested inside another one (`SHLVL` > 1), so you know `exit` won't close the terminal |
| `⟨ ⚙ 2 ⟩` | Background jobs |
| `✖ 1\|0\|1 FAULT (・_・;)` | Exit status of the last command, one code per pipeline stage if it was a pipeline, with a label (`NOT-FOUND`, `SIGINT`, `SIGKILL`, …) and KAGARI's reaction |
| `⏱ 4.2s` | Runtime of commands slower than `duration` seconds |
| `炉 18:11:36` | Clock |

On a narrow terminal the prompt drops detail instead of wrapping. The clock goes first, then the status label, then the path is shortened, then the context and git segments go. A failed command's exit code is always the last thing to go.

## Quick start

```bash
./install.sh                 # → open a new terminal, or: exec bash
```

Later, to get the newest version:

```bash
./update.sh --pull           # or, from any neosh shell: neo update --pull
```

That's all. The installer works for your user only: it needs no root, uses no network and doesn't run `chsh`. It runs a self-test before touching anything, backs up `~/.bashrc`, and adds a small marked block at the end of it. Re-run it any time to upgrade.

```bash
./install.sh --theme sakura --boot full   # pick a theme and the long boot log
./install.sh --no-hook                    # don't touch ~/.bashrc; start it with `neosh`
```

## Running neosh inside an existing terminal

The installer also puts a `neosh` command in `~/.local/bin`. Type it in any open terminal, whether that's plain bash, zsh or fish, to start a neosh session inside it. `exit` takes you back to where you were.

```bash
neosh                 # interactive bash + your ~/.bashrc + the neosh HUD
neosh script.sh       # with arguments it is exactly `bash script.sh`
NEOSH_DISABLE=1 bash  # the opposite: one plain-bash session
```

Install with `--no-hook` if you want plain bash by default and neosh only when you ask for it.

## Command deck

`neo` (Tab-completes) is the command deck:

| Command | Action |
|---|---|
| `neo` / `neo help` | List of commands |
| `neo status` | System HUD: **01 CORE** 炉心 (load, cores, uptime, memory, swap), **02 THERMAL** 熱源 (hottest sensor), **03 STORAGE** 記憶域 (`/` and `$HOME`), **04 NETWORK** 通信 (interfaces, default route), **05 SHELL** 殻. KAGARI sums it up and warns about heat, full disks, memory pressure or high load. |
| `neo theme` | Show the themes with colour swatches |
| `neo theme NAME` | Switch theme (saved) |
| `neo theme add NAME A1 A2 A3 [DIM FAINT]` | Save a custom theme from hex colours (see *Custom themes*) and preview it |
| `neo theme rm NAME` | Delete a custom theme |
| `neo preview [NAME…]` | Draw your actual prompt (this directory, this repo) in every theme, or just the ones named, with a failed 4.2 s command so the status colours show too |
| `neo boot full\|compact\|off` | Startup banner style |
| `neo set KEY VALUE` | Change any setting below (saved, applied live) |
| `neo config` | Show the current settings and the config file path |
| `neo nav` | Ask KAGARI how things are |
| `neo off` | Hand the prompt back to plain bash for this session (`neo reload` brings it back) |
| `neo reload` | Reload neosh in the current shell |
| `neo update [--pull]` | Run `update.sh` from the checkout you installed from, then reload this shell. `--pull` gets the newest version from GitHub first |
| `neo version` | Version info |
| `neo uninstall` | Run the uninstaller |

## Themes & KAGARI

- Nine themes with the same palettes as HEARTH: **HEARTH** 炉心, **REDLINE** 赤警報, **MECHA** 機甲, **SAKURA** 桜, **ECLIPSE** 月蝕, **KURENAI** 紅, **ABYSS** 深海, **AURUM** 黄金 and **SPECTER** 幽霊. As in HEARTH, the status colours (green / amber / red) are the same in every theme. You can add your own (see *Custom themes*), and `neo preview` shows your prompt in all of them.
- Truecolor is used when the terminal supports it (kitty, GNOME Terminal, Konsole, Alacritty, WezTerm, foot, Ghostty…). Otherwise neosh falls back to the 256-colour palette. `NO_COLOR` is respected.
- On the Linux console (`TERM=linux`) or a non-UTF-8 locale, neosh switches to plain ASCII glyphs (`.-[ user@host ]-( ~/src )`).
- KAGARI greets you depending on the time of day, reacts to failed commands in the prompt, reads `neo status` out, and answers `command not found` when your distro doesn't have its own handler. Fedora's PackageKit handler is left in place. Turn her off with `neo set navigator off`.
- Between commands KAGARI keeps an eye on you. After three, five or ten failures in a row she says something, and she cheers when the streak ends. Ctrl-C and Ctrl-Z don't count as failures. Between 02:00 and 05:00 she suggests going to bed, at most once an hour. `neo set quips off` silences only these remarks.

### Custom themes

Add a line to the config, or let `neo` write it for you:

```bash
neo theme add neon '#ff00aa' '#00ffcc' '#ffee00'    # → theme.neon = #ff00aa #00ffcc #ffee00 #ae69ad #5f395f
neo theme neon
```

The three colours are the accents (`A1` is used for the identity segment and the arrow, `A2` for git, `A3` for context). Two more set `DIM` (clock, labels) and `FAINT` (frame lines). If you leave them out, they're derived from `A1`. Custom themes show up in `neo theme`, `neo preview` and Tab completion. Like the rest of the config, these lines are parsed, never run: a name of `a-z 0-9 _` that isn't a built-in, and 3 or 5 `#rrggbb` values, or the line is ignored. Up to 32 custom themes.

### Transient prompt

`neo set transient on` (experimental). Once you press Enter, the two-line HUD you typed into is redrawn as one line, so scrollback is just commands and their output, and only the live prompt has the full HUD:

```
▶ git status
On branch main
nothing to commit, working tree clean

▶ make test
…

╭─◢ n3tvoid@hypr ◣─⟨ ~/src/neosh ⟩─⟨ ⎇ main ✓ ⟩───────────────── 炉 18:12:03
╰─▶
```

Enter is bound to a readline macro: a `bind -x` hook that only measures how many rows the prompt and the input took, followed by the normal `accept-line`. `PS0` then moves the cursor back up and redraws the prompt as the short version. It works in emacs and vi mode, with reverse-i-search, wrapped lines, multi-line commands and pastes. If your Enter key is already bound to something other than `accept-line`, neosh leaves it alone and doesn't turn this on. If you press Ctrl-C at a `┊` continuation line, the full prompt stays.

## Configuration

`~/.config/neosh/neosh.conf`. Edit it by hand or with `neo set`. For a single session you can also use `NEOSH_THEME=abyss bash` or `NEOSH_BOOT=full bash`.

| Key | Default | Values | |
|---|---|---|---|
| `theme` | `hearth` | see *Themes* | Colour theme, built-in or custom |
| `boot` | `compact` | `full` `compact` `off` | Startup banner: boot log, one line + greeting, or nothing |
| `color` | `auto` | `auto` `truecolor` `256` `off` | Colour depth |
| `glyphs` | `auto` | `auto` `unicode` `ascii` | Box-drawing / kanji, or plain ASCII |
| `prompt` | `on` | `on` `off` | `off` leaves `PS1` completely alone (keep only `neo` and KAGARI) |
| `navigator` | `on` | `on` `off` | KAGARI's greeting, kaomoji and messages |
| `clock` | `on` | `on` `off` | Clock on the right |
| `git` | `on` | `on` `off` | Branch segment |
| `git_dirty` | `on` | `on` `off` | Runs `git status` to show `●` / `✓` (turn off for huge repos) |
| `title` | `on` | `on` `off` | Set the terminal window title |
| `spacing` | `on` | `on` `off` | Blank line between prompts |
| `shlvl` | `on` | `on` `off` | `↳ N` for nested shells. Some terminals and tmux start shells at `SHLVL` 2, so turn it off there if it's always shown |
| `quips` | `on` | `on` `off` | KAGARI's remarks on failure streaks and late nights (needs `navigator on`) |
| `transient` | `off` | `on` `off` | Collapse old prompts to `▶ command` (see *Transient prompt*) |
| `duration` | `3` | `0`–`9999` | Show runtime of commands slower than N seconds (`0` = never) |
| `path_depth` | `4` | `1`–`99` | Folders shown before the path is shortened with `…` |

## Updating

```bash
./update.sh               # install this directory as it is (or: neo update)
./update.sh --pull        # git pull from GitHub first (or: neo update --pull)
```

`update.sh` runs `install.sh` again from the files in this directory, local edits included, with the same choice you made the first time (hook or `--no-hook`). Your config, custom themes and `~/.bashrc` backup stay as they are. Without `--pull` it doesn't use git or the network at all.

With `--pull` it first runs `git pull --ff-only` and lists the new commits. It never merges or rebases. If you have uncommitted changes to tracked files, the branch has no upstream, or the pull fails, it stops and installs nothing.

If the installed files already match the checkout, it changes nothing. The installer records where it was installed from, so `neo update` finds the checkout by itself and reloads the shell you ran it in. Other open shells pick up the new version with `neo reload`.

## Uninstall

```bash
./uninstall.sh            # asks first; or: neo uninstall
./uninstall.sh -y --purge # no question, and also delete config + backup
```

It puts you back on plain bash with your own `~/.bashrc`:

| Removed | Only if |
|---|---|
| The `# >>> neosh >>>` … `# <<< neosh <<<` block in `~/.bashrc` | Always. Everything you added before or after it stays as it is. Without later edits the file is byte-for-byte identical to before the install. |
| `~/.local/bin/neosh` | It contains the neosh launcher marker (a different program named `neosh` is left alone) |
| `~/.local/share/neosh/` | It contains the neosh runtime and isn't a symlink |
| `~/.bashrc` itself | The installer created it because you had none, and it still holds nothing else |
| `~/.config/neosh/` and the `~/.bashrc.neosh-backup.*` file | Only with `--purge` |

If your login shell was ever pointed at `neosh` by hand, it's set back to bash first. Terminals that are already open keep the HUD until you run `exec bash` or open a new one.

## Security notes

neosh is not a re-implementation of bash. A new shell written from scratch would lose decades of hardening, and your distro's security updates wouldn't reach it. Instead neosh is a layer of ordinary bash functions loaded into your real, distro-patched `/bin/bash`, so the parser, builtins, job control, completion, history and restricted mode are all bash's own. On top of that:

- **Only interactive shells.** Scripts, `bash -c`, cron, scp/rsync and sudo never load it, so their behaviour can't change.
- **Your login shell stays `/bin/bash`.** Nothing runs `chsh` and nothing is added to `/etc/shells`. A broken neosh install can't lock you out of a TTY or SSH session, and `NEOSH_DISABLE=1 bash` always gives you plain bash.
- **Prompt injection is closed.** `PS1` only *references* variables and bash doesn't re-expand their values, so a directory or branch named `$(rm -rf ~)`, `` `id` `` or `\u` is displayed literally and never runs. Control characters (including terminal escape sequences) are stripped from paths, branch names and the window title. The test suite checks this against a deliberately naive prompt that *is* exploitable.
- **Hostile repositories.** The branch is read straight from `.git/HEAD` without starting git. The `●`/`✓` check runs `git status` with `core.fsmonitor` disabled and optional locks off, so a repo's config can't use the fsmonitor hook to run a program, and the index is never written. This is the same exposure as running `git status` yourself. Set `git_dirty=off` if you browse untrusted checkouts.
- **The config file is parsed, never sourced.** Only the keys above are read, each value is validated, and the file is ignored if you don't own it. At worst a tampered config can change a colour.
- **The installer is careful.** It refuses to run as root by default. It won't overwrite a `neosh` it didn't create. It follows a symlinked `~/.bashrc` (stow, chezmoi, yadm) and edits the target, so your link survives. Every file is written to a temp file and renamed into place, and the new `~/.bashrc` must pass `bash -n` before it replaces the old one. Both scripts are read in full before they start, so they can't be changed partway through a run.
- **Updates are explicit.** Only `update.sh --pull` / `neo update --pull` touch the network, by running `git pull --ff-only` in your own checkout, and only when you run them. Nothing checks for updates in the background. The pulled code goes through the same installer and self-test as a fresh install.
- **History.** neosh doesn't change `HISTCONTROL`, `HISTSIZE` or `HISTFILE`. It only turns on `histappend` (and `checkwinsize`), so parallel terminals don't overwrite each other's history.

## How it works

```
terminal ──▶ /bin/bash -i ──▶ /etc/bashrc ──▶ ~/.bashrc ──▶ [neosh hook] ──▶ ~/.local/share/neosh/neosh.bash
                                                                                ├─ PROMPT_COMMAND  (renders the HUD)
                                                                                ├─ PS0             (stamps start time, transient redraw)
                                                                                └─ neo, completion, KAGARI
```

- Each prompt is built with bash builtins: one subshell for the job count, and the optional `git status` as the only external program, run only inside a repository. It takes about 1–2 ms outside a repo and about 4 ms inside one with `git_dirty` on.
- The neosh hook runs **first** in `PROMPT_COMMAND`, so it sees the real `$?` and `PIPESTATUS`. Hooks that are already there (vte.sh, direnv…) keep running after it, unchanged.
- Command timing uses `PS0`, so no `DEBUG` trap is needed and the timing doesn't clash with your own traps.
- Requires bash ≥ 4.4 (command timing needs ≥ 5.0).

| Path | What |
|---|---|
| `install.sh` / `uninstall.sh` | Installer / uninstaller |
| `update.sh` | Reinstall from the checkout with the same options (`--pull`: `git pull --ff-only` first) |
| `lib/neosh.bash` | The runtime: prompt, themes, `neo`, KAGARI |
| `lib/neoshrc` | rcfile for the `neosh` launcher (`~/.bashrc`, then neosh) |
| `share/neosh.conf` | Default config |
| `tests/run.sh` | Test suite. Every case runs in a throwaway `$HOME`. |

## Tests

```bash
tests/run.sh
```

85 checks: install / re-install / uninstall round trips (including a symlinked `~/.bashrc`, no `~/.bashrc`, and `--no-hook`), the loading rules (interactive only, `NEOSH_DISABLE`, launcher pass-through), injection through config values, custom theme lines, branch names, directory names and escape sequences, custom themes and `neo preview`, the `SHLVL` segment, KAGARI's remarks (the late-night one uses a faked time zone), the transient prompt in a real pseudo-terminal (needs `python3`, skipped otherwise), `update.sh` from local files and with `--pull` against a throwaway git remote, and the installer's refusals.

## License

AGPL-3.0, same as HEARTH.
