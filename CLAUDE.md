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
| `install.sh` | Symlinks `hydra` into `~/.local/bin`, appends the `source` line to `~/.zshrc`. |
| `test/run.sh` | The test suite. TAP-style output, no dependencies beyond bash + jq. |
| `.github/workflows/test.yml` | Runs the suite on macOS and Ubuntu. |

Runtime state lives outside the repo in `$HYDRA_HOME` (default `~/.hydra`):
`profiles.json` (the manifest — names, dirs, emails, tuning; no secrets),
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
with no data at all (first launch after sign-in).

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
`set_usage <name> …` serves it and fetches it into the cache. New behaviour
gets a test in the matching section; the suite must stay green on both CI
platforms — Ubuntu has already caught a macOS-only assumption once.

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
