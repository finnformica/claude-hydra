# CLAUDE.md

Guidance for Claude Code (and humans) working on this repository.

## What this is

`hydra` keeps one Claude Code config directory per subscription and routes each
`claude` launch to the account with the most headroom. It is a launcher, not a
daemon: one bash script, a shell function, and a usage cache. See README.md for
the user-facing behaviour; this file is about how the code is put together and
the invariants that are easy to break.

## Layout

| File | Role |
|---|---|
| `hydra` | The whole CLI, one bash script. Sections in order: utilities, manifest, credentials, model intent, usage (fetch/snapshot/refresh/pick), linking, commands, dispatch. |
| `hydra.sh` | Sourced by the user's rc file. Defines the `claude()` function (→ `hydra exec "$@"`) and zsh/bash tab completion. |
| `claude-shim` | Opt-in stand-in for the `claude` binary on PATH (→ `hydra exec "$@"`), so launchers that bypass the shell function are routed too. Carries the `hydra-shim` marker in its header. |
| `install.sh` | Symlinks `hydra` into `~/.local/bin`, appends the `source` line to `~/.zshrc`. `--shim` records the real binary and links `~/.local/bin/claude` to the shim; `--unshim` restores it. |
| `test/run.sh` | The test suite. TAP-style output, no dependencies beyond bash + jq. |
| `.github/workflows/test.yml` | Runs the suite on macOS and Ubuntu. |

Runtime state lives outside the repo in `$HYDRA_HOME` (default `~/.hydra`):
`profiles.json` (the manifest — names, dirs, emails, tuning, `claude_bin`; no secrets),
`cache/<name>.json` (usage snapshots), `profiles/<name>/` (each profile's
`CLAUDE_CONFIG_DIR`). The default profile is `~/.claude` itself.

## Commands

```sh
test/run.sh              # all tests (~10 s)
test/run.sh pick         # tests whose name contains "pick"
bash -n hydra install.sh hydra.sh test/run.sh
```

There is no build step. Editing `hydra` in the repo changes the installed
command immediately (it is symlinked).

## Invariants — read before changing anything

**Portability.** The script must run on macOS's stock bash 3.2 and jq 1.6, and
on Linux. So: no associative arrays, no `${var,,}`, no `mapfile`, no
`readarray`; no jq features newer than 1.6 (`fromdateiso8601` needs the `ts`
helper because it rejects fractional seconds and `+00:00`). `exec claude`, not
`exec command claude` — bash cannot exec a builtin, and macOS only hid that
behind its `/usr/bin/command` shim (CI caught it).

**The Keychain item name is a hash of the exact string.** Claude Code stores a
non-default profile's credentials under
`Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>`, hashing
the env var verbatim (no realpath, no trailing-slash normalisation). hydra must
therefore export precisely the string it hashes in `service_name`: the
`~`-expanded manifest path with any trailing slash stripped at `add` time. Never
"tidy" a dir string between storing it and exporting it. The default profile
(`~/.claude`) uses the bare `Claude Code-credentials` item.

**`.claude.json` lives in two different places.** For the default profile it is
`~/.claude.json` (beside `~/.claude`, not inside); for every other profile it is
`<dir>/.claude.json`. Always go through `claude_json`.

**Tokens never leave the machine.** Nothing under `$HYDRA_HOME` except the
per-profile dirs holds a credential, and those are never copied, exported or
committed. The manifest is designed to be shareable via dotfiles.

**Launch never waits on the network.** `cmd_exec` picks from cached numbers and
`exec`s; a stale cache is refreshed by a detached `( "$0" refresh … & )` after
the pick. The only synchronous fetch is `ensure_usage`, for a signed-in profile
with no data at all (first launch after sign-in).

**hydra never runs `claude` by name.** With the shim installed, the `claude` on
PATH *is* hydra, so `exec claude` (or `command claude`) would recurse. Every
launch goes through `launch`/`run_claude`, which use `claude_bin`:
`HYDRA_CLAUDE_BIN` → manifest `claude_bin` (if it runs here) → the first
`claude` on PATH that `is_shim` rejects — `is_shim` matches the `hydra-shim`
marker in the first 512 bytes, or hydra's own file (`-ef "$0"`). The result is
symlink-resolved (`real_path`, no `readlink -f` — older macOS lacks it), because
`install.sh --shim` records it *before* replacing the link it was found
through. `launch` execs with `-a claude` so argv[0] is unchanged, and exports
`HYDRA_LAUNCH_PID=$$`; the shim exits 70 if it is entered with that pid (exec
keeps the pid), so a mis-resolved binary fails loudly rather than looping.
The only `command claude` left is the shell function's fallback for when hydra
is not on PATH, which cannot reach hydra and so cannot recurse.

**The routing hint is for terminals only.** `hint` prints when stderr is a TTY
(`[ -t 2 ]`); `HYDRA_QUIET=1` always silences it, `HYDRA_QUIET=0` always
prints it. A headless `claude -p` captures stderr for error text; nothing
hydra-ish may appear there. `die` is unaffected.

**Cache writes are atomic.** `fetch_usage` writes to a temp file and `mv`s it;
`snapshot` tolerates an unreadable file. A launch can read a cache while a
background refresh is writing it — this was a real bug.

**The usage endpoint is undocumented and rate-limited.** `GET
https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer`,
`anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version>` (a
non-first-party UA gets a much smaller budget). Never poll faster than
`MIN_REFRESH_S` (180 s). The parser reads the `limits[]` array — `kind`
`session` (5-hour), `weekly_all`, and `weekly_scoped` with
`scope.model.display_name == "Fable"` — and treats a missing bucket as `null`,
never as an error. Claude Code writes the same shape to
`.claude.json.cachedUsageUtilization` after each session; `snapshot` uses
whichever of the two sources is newer.

**A new config dir triggers Claude's first-run wizard.** `seed_state` copies the
onboarding markers (`hasCompletedOnboarding` etc.) from `~/.claude.json` into a
profile at `add`/`login`/`link`, adding only keys the profile lacks. Without it
the first interactive launch asks the user to sign in even though they already
have.

**Shared config is symlinked, per item.** `SHARED_DIRS`/`SHARED_FILES` list what
every profile shares with `~/.claude`. Directories are created in `~/.claude`
if missing so the link always resolves; files are linked only if they exist.
`.claude.json`, `history.jsonl`-style per-session state, `sessions/` and the
credentials are never shared. `link_shared` is idempotent and repairs wrong
targets; it replaces a real file only with `--force` (keeping a `.hydra-bak`).

**Reserved names.** A profile name may not collide with a hydra subcommand
(`HYDRA_CMDS`), a Claude subcommand (`PASSTHROUGH`), or `auto`/`best`, because
`hydra <name>` and `claude <name>` dispatch on the first argument. Add new
subcommands to `HYDRA_CMDS` *and* to the completion lists in `hydra.sh`.

**The shim install is reversible and idempotent.** `install.sh --shim` moves
whatever is at `$bin/claude` (file or symlink, even a dangling one) to
`claude.hydra-bak` and links the shim; `--unshim` moves it back and clears
`claude_bin`. A regular file there (a copied binary) is moved, never deleted,
and `claude_bin` then points at the `.hydra-bak`. The record happens before the
link, and the move is undone if the record fails.

## The ranking, precisely

In `pick_json` (jq). Per enabled, signed-in profile, with `now` and the manifest:

1. `eff(bucket; grace)`: a bucket whose `resets_at <= now + grace` is 0. Grace is
   `reset_grace_minutes` for the 5-hour window, 0 for the weekly ones.
2. Intent (`model_intent`): `--model` arg → `$HYDRA_MODEL` → `model` in
   `~/.claude/settings.json` → manifest `default_model` → `fable`. Anything not
   containing "fable" is a non-Fable session and the Fable bucket becomes `null`.
3. `exhausted` = locked, or `max(s, w, f) >= threshold`.
4. `score` = Fable: `max(s·w_session, f·w_fable)`; other: `max(s·w_session, w·w_weekly)`.
5. Non-exhausted profiles are ranked; if none, all are.
6. Sort by: known-before-unknown, `floor(score / 5)`, weekly, 5-hour `resets`.

Change the tests in `test/run.sh` under `# pick:` in step with any change here.

## Testing conventions

Each test runs in a sandbox (`sandbox()` in `test/run.sh`): a throwaway `$HOME`
with a fake `~/.claude`, `HYDRA_HOME` under it (so `~` contraction works), a
fake `claude` (records args; `auth login` writes fake credentials) and a fake
`curl` (serves `$FAKE_CURL_BODY` with `$FAKE_CURL_CODE`) first on `PATH`,
`HYDRA_NO_KEYCHAIN=1` so credentials are files, and `HYDRA_NOW` for a fixed
clock. `usage <5h> <weekly> <fable> [resets…]` builds an endpoint body;
`set_usage <name> …` serves it and fetches it into the cache. Tests that read
the hint from a pipe set `HYDRA_QUIET=0`. `shim_on` runs `install.sh --shim`
into `$SB/lbin` and puts it first on PATH, so `bash -c 'claude …'` goes shim →
hydra → the fake; `real` resolves a path the way `hydra bin` prints it
(macOS's `/var` is `/private/var`); `with_tty` runs a command on a pty via
`script(1)` (util-linux and BSD forms); `tool_path` builds a PATH with every
tool hydra needs and no `claude` at all. New behaviour gets a test in the
matching section; the suite must stay green on both CI platforms — Ubuntu has
already caught a macOS-only assumption once.

## Style

Bash with `set -euo pipefail`; functions are small and named for what they
return (`profile_dir`, `credentials`, `snapshot`). Comments explain *why*
(an invariant, a Claude Code quirk), not what the line does. Messages to the
user go to stderr via `say`/`hint`; stdout is reserved for values scripts
consume (`pick`, `dir`, `names`). Keep the table output ASCII so `printf`
widths hold.

## Before committing

- `test/run.sh` and `bash -n` on every script
- README.md if user-visible behaviour changed; this file if an invariant did
- Never commit anything from `~/.hydra` or a real `.claude.json`
