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
| `hydra` | The whole CLI, one bash script. Sections in order: utilities, manifest, credentials, model intent, usage (fetch/snapshot/refresh/rank/pick), teleport, linking, commands, dispatch. |
| `hydra.sh` | Sourced by the user's rc file. Defines the `claude()` function (→ `hydra exec "$@"`) and zsh/bash tab completion. |
| `claude-shim` | Opt-in stand-in for the `claude` binary on PATH (→ `hydra exec "$@"`), so launchers that bypass the shell function are routed too. Linked as `$HYDRA_HOME/bin/claude`, *ahead of* the real binary, never in its place. Carries the `hydra-shim` marker in its header. |
| `install.sh` | Symlinks `hydra` into `~/.local/bin`, appends the `source` line to `~/.zshrc`. `--shim` links `$HYDRA_HOME/bin/claude` to the shim and adds a marked `export PATH=…` line to the rc; `--unshim` removes both. Both migrate the old in-place layout. |
| `test/run.sh` | The test suite. TAP-style output, no dependencies beyond bash + jq. |
| `.github/workflows/test.yml` | Runs the suite on macOS and Ubuntu. |

Runtime state lives outside the repo in `$HYDRA_HOME` (default `~/.hydra`):
`profiles.json` (the manifest — names, dirs, emails, tuning, an optional
`claude_bin` pin; no secrets), `cache/<name>.json` (usage snapshots),
`profiles/<name>/` (each profile's `CLAUDE_CONFIG_DIR`), and `bin/claude` (the
shim, when installed). The default profile is `~/.claude` itself.

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
`readarray`; bracket ranges like `[a-z]` are locale-collated in bash 3.2 (they
match capitals under `en_US.UTF-8`), so `valid_name` checks its character set
through `LC_ALL=C tr`; no jq features newer than 1.6 (`fromdateiso8601` needs the `ts`
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
with no data at all (first launch after sign-in). The one deliberate exception
is a teleport, below.

**A teleport is routed on ownership, not headroom.** A claude.ai/code session
is visible only to the account that created it, and Claude Code resolves
`--teleport <id>` with exactly one request, `GET
https://api.anthropic.com/v1/code/sessions/<id>` with `Authorization: Bearer`
and `anthropic-version: 2023-06-01` (found by reading the binary: a 404 is what
it prints as "Session not found", a 401 "Session expired"). When a bare launch
carries an id (`teleport_id`: `--teleport <v>` or `--teleport=<v>`, the value
reduced to its last path component with any query string dropped, so the web
UI's URL and the bare id are the same; anything outside `[A-Za-z0-9_-]` or a
bare `--teleport` yields nothing and the ordinary pick runs), `teleport_route`
probes every signed-in profile in `rank_json … --all` order — disabled ones
last but included, since nothing else can teleport their sessions — and stops
at the first 200. No 200: the best-ranked profile whose answer was not 404
(401, offline, anything undecided) is launched and the hint says why, because
Claude Code will refresh a stale token and answer for itself. Every profile
404: `die`, naming them; nothing is launched. A named profile skips the probe.
The endpoint is undocumented like the usage one, but the probe is one request
per profile per teleport, so no rate-limit floor applies. `PASSTHROUGH` is
untouched: `--teleport` is a flag, not a subcommand.

**hydra never runs `claude` by name.** With the shim installed, the `claude` on
PATH *is* hydra, so `exec claude` (or `command claude`) would recurse. Every
launch goes through `launch`/`run_claude`, which use `claude_bin`: the first
`claude` on PATH that `is_shim` rejects (`find_claude_bin`) is the *default*,
walked afresh on every launch; `HYDRA_CLAUDE_BIN`, then a manifest `claude_bin`
(only if it runs here), are explicit pins that override it and nothing writes
them but the user. `is_shim` matches the `hydra-shim` marker in the first 512
bytes, or hydra's own file (`-ef "$0"`). The result is symlink-resolved
(`real_path`, no `readlink -f` — older macOS lacks it). `launch` execs with
`-a claude` so argv[0] is unchanged, and exports `HYDRA_LAUNCH_PID=$$`; the shim
exits 70 if it is entered with that pid (exec keeps the pid), so a mis-resolved
binary fails loudly rather than looping. The shell function's fallback
`command claude` (hydra not on PATH) reaches at most the shim, which execs
hydra by its own path, so it cannot recurse either.

**The shim shadows the real binary; it never replaces it.** It is linked at
`$HYDRA_HOME/bin/claude` and `hydra.sh` puts that directory first on PATH
(when it exists; `install.sh --shim` also appends a line marked `# hydra-shim`
to the rc). `~/.local/bin/claude` is never moved, so Claude Code's updater can
rewrite it and the next launch simply finds the new binary. This is why
`install.sh --shim` must not record `claude_bin`: a pin is exactly what went
stale under the old layout. Nothing enforces the PATH order at launch — a
launcher whose PATH lacks `$HYDRA_HOME/bin` never reaches hydra — so `doctor`
(`shim_installed`, `first_claude_on_path`, `shim_bypassed_by`) and the one
stderr warning in `status` are the only places that failure is visible. Keep
them honest: `doctor` exits non-zero for every finding and prints a fix line.
`hydra.sh` exports `HYDRA_SOURCED=1` (and `unalias claude`s first, since an
alias beats a function in zsh); `rc_sourced` is how `doctor` and the `status`
warning tell "this shell never ran the rc lines: reload it" from "the PATH is
wrong". The test sandbox sets the marker, standing in for a sourced shell;
tests for the unsourced case use `env -u HYDRA_SOURCED`.
`doctor` is also a Claude subcommand: `hydra doctor` is ours, `claude doctor`
still passes through.

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

**The STATE column and `status --json` share one rule.** `state($threshold)` in
`JQ_LIB` is the only place that decides `ok` / `exhausted` / `locked` / …; the
table and the JSON both call it, and `--json` is `snapshots` plus that field,
nothing re-derived. Orca reads the JSON strings verbatim, so changing one means
changing the test under `# status:` too.

**Reserved names.** A profile name may not collide with a hydra subcommand
(`HYDRA_CMDS`), a Claude subcommand (`PASSTHROUGH`), or `auto`/`best`, because
`hydra <name>` and `claude <name>` dispatch on the first argument. Add new
subcommands to `HYDRA_CMDS` *and* to the completion lists in `hydra.sh`.
`update` is in both lists on purpose, like `doctor`: `hydra update` is ours,
`claude update` still reaches Claude Code's updater.

**`hydra update` is a fast-forward pull of the checkout `$0` resolves into.**
Because `~/.local/bin/hydra` and the shim are symlinks into the clone, the pull
is the whole update; the command refuses on local changes, a detached HEAD or
a copy that is not a checkout, and only tells the user to reload the shell when
`hydra.sh` itself changed. It never touches `$HYDRA_HOME`.

**The shim install is reversible and idempotent, and migrates the old layout.**
Before the shadow layout, `--shim` put the shim *in place of* `$bin/claude`,
kept the original as `claude.hydra-bak` and pinned `claude_bin`; the updater
then overwrote the link and left the pin stale. `restore_old_layout` (run by
both `--shim` and `--unshim`) puts `$bin/claude` back from the backup, removes
an old shim with no backup, drops a stale backup when the updater has already
put a real `claude` there (a symlink; a regular-file backup is only reported,
never deleted), and clears `claude_bin` — printing each step, and nothing on a
second run. `--shim` still refuses when no real binary resolves.

## The ranking, precisely

In `rank_json` (jq); `pick_json` is its first element. Per enabled, signed-in
profile (`--all` keeps disabled ones, sorted last — the teleport probe order),
with `now` and the manifest:

1. `eff(bucket; grace)`: a bucket whose `resets_at <= now + grace` is 0. Grace is
   `reset_grace_minutes` for the 5-hour window, 0 for the weekly ones.
2. Intent (`model_intent`): `--model` arg → `$HYDRA_MODEL` → `model` in
   `~/.claude/settings.json` → manifest `default_model` → `fable`. Anything not
   containing "fable" is a non-Fable session and the Fable bucket becomes `null`.
3. `exhausted` = locked, or `max(s, w, f) >= threshold`.
4. `score` = Fable: `max(s·w_session, f·w_fable)`; other: `max(s·w_session, w·w_weekly)`.
5. Sort by: enabled first, non-exhausted first, known-before-unknown,
   `floor(score / 5)`, weekly, 5-hour `resets`. (Exhausted profiles are ranked
   rather than dropped so the teleport probe still reaches them; for the pick
   this is the same winner as setting them aside.)

Change the tests in `test/run.sh` under `# pick:` in step with any change here.

## Testing conventions

Each test runs in a sandbox (`sandbox()` in `test/run.sh`): a throwaway `$HOME`
with a fake `~/.claude`, `HYDRA_HOME` under it (so `~` contraction works), a
fake `claude` (records args; `auth login` writes fake credentials) and a fake
`curl` (serves `$FAKE_CURL_BODY` with `$FAKE_CURL_CODE`) first on `PATH`,
`HYDRA_NO_KEYCHAIN=1` so credentials are files, and `HYDRA_NOW` for a fixed
clock. `usage <5h> <weekly> <fable> [resets…]` builds an endpoint body;
`set_usage <name> …` serves it and fetches it into the cache. The fake curl
answers the sessions endpoint per bearer token from `$FAKE_SESSIONS` (a token
not listed gets 404): `sessions a=404 b=200` writes it for the sandbox's
`tok-<name>@example.com` tokens, and `probes` counts how many profiles a
launch asked. The `update` test builds its own origin and clone under the
sandbox and runs the clone's `hydra` through a symlink, never the repo's
checkout. Tests that read the hint from a pipe set `HYDRA_QUIET=0`. `fake_claude <path> <version>` writes
the fake anywhere (an "update" is a second one with a new version);
`native_layout` moves it to `$SB/real/claude` with `$SB/lbin/claude` linking
to it — the macOS native install shape, `$SB/lbin` standing in for
`~/.local/bin`; `shim_install` runs `install.sh` against `$SB/lbin` and
`$SB/rc`; `shim_on` installs the shim and puts `$HYDRA_HOME/bin` first on
PATH (what `hydra.sh` does), so `bash -c 'claude …'` goes shim → hydra → the
fake; `shim` prints the shim's path; `real` resolves a path the way `hydra bin`
prints it (macOS's `/var` is `/private/var`); `with_tty` runs a command on a
pty via `script(1)` (util-linux and BSD forms); `tool_path` builds a PATH with
every tool hydra needs and no `claude` at all. New behaviour gets a test in
the matching section; the suite must stay green on both CI platforms — Ubuntu
has already caught a macOS-only assumption once.

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
