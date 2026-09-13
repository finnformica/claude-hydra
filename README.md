# claude-hydra

Many heads, one Claude Code.

`hydra` keeps one Claude Code profile per subscription and routes every
`claude` launch to the account with the most headroom — across the 5-hour
window, the weekly window, and the Fable weekly window. Cut one head off and
the next one bites.

```
$ claude
hydra → work   5h 12%   week 30%   Fable 8%
…Claude Code starts on the work account…

$ claude personal --resume       # force a profile; everything after it is passed to claude
$ claude mcp list                # claude's own subcommands are left alone

$ hydra status
PROFILE      ACCOUNT                           5H  WEEK  FABLE  5H-RESET AGE    STATE
personal     you@example.com                  71%   40%    62%  1h05m    2m     ok
work         you@work.example                 12%   30%     8%  4h50m    2m     ok
```

Your shell command stays `claude`, with every argument passed through untouched.

## Install

On each machine:

```sh
git clone https://github.com/finnformica/claude-hydra ~/.local/share/claude-hydra
~/.local/share/claude-hydra/install.sh     # links ~/.local/bin/hydra, sources hydra.sh from ~/.zshrc
exec $SHELL
```

Needs `jq` and `curl` (`brew install jq`). macOS and Linux; bash 3.2+.

Then register accounts:

```sh
hydra add personal --existing    # the account already signed in to ~/.claude — no re-login
hydra add work                   # creates a profile and opens the sign-in flow
hydra status
```

## Commands

| | |
|---|---|
| `hydra add <name> [--existing \| --dir PATH] [--no-login]` | new profile; `--existing` registers `~/.claude` itself |
| `hydra login <name>` | sign in, or sign in again when a token has expired |
| `hydra remove <name> [--keep-files]` | delete the profile, its Keychain entry and its directory |
| `hydra rename <old> <new>` | relabel a profile; its sign-in is untouched |
| `hydra disable <name>` · `hydra enable <name>` | keep a profile signed in but out of the rotation (`claude <name>` still works) |
| `hydra list` | profiles and their config dirs |
| `hydra status [--cached\|--force]` | usage table; refreshes anything older than 3 minutes |
| `hydra refresh [names…] [--force]` | fetch usage now |
| `hydra pick [--json] [--model M]` | which profile a bare `claude` (or `claude --model M`) would use right now |
| `hydra link [names…] [--force]` | (re)apply the shared-config symlinks |
| `hydra dir <name>` · `hydra has <name>` | plumbing for scripts |
| `hydra exec [profile] [claude args…]` | what the `claude` shell function calls |
| `hydra <profile> [claude args…]` | shorthand for `hydra exec <profile> …` |

Tab completion (zsh and bash) comes with `hydra.sh`: `hydra <Tab>` offers
commands and profiles, `hydra login <Tab>` and `claude <Tab>` offer profiles.

`HYDRA_QUIET=1` suppresses the one-line routing hint. `HYDRA_MODEL=opus`
scores launches for that model when no `--model` is passed. `HYDRA_HOME` (default
`~/.hydra`) and `HYDRA_MANIFEST` (default `$HYDRA_HOME/profiles.json`) move the
state.

## How a profile is chosen

For each enabled, signed-in profile hydra takes the three percentages Claude
Code shows in `/usage`, then:

1. A window that has already reset — or a 5-hour window resetting in the next
   10 minutes — counts as 0 %.
2. Profiles at or over the threshold (90 %) or locked are set aside, unless
   *every* profile is.
3. The score depends on the model the session will use:
   - **Fable** — `max(session × w_session, fable × w_fable)`: the 5-hour window
     and the Fable weekly window are both first-class; whichever binds decides.
   - **anything else** (`--model opus`, `sonnet`, …) — the Fable window is
     irrelevant, so `max(session × w_session, weekly × w_weekly)`; a profile whose
     Fable window is spent is a perfectly good Opus profile.
4. Ties within 5 points go to the lower all-models weekly figure, then to the
   soonest 5-hour reset.

The model is read from `--model` in the arguments, else `$HYDRA_MODEL`, else
the `model` in `~/.claude/settings.json`, else `default_model` in the manifest.

Threshold, weights, grace and default model live in `profiles.json`:

```json
{
  "version": 1,
  "threshold": 90,
  "weights": { "session": 1, "fable": 1, "weekly": 1 },
  "reset_grace_minutes": 10,
  "default_model": "fable",
  "profiles": {
    "personal": { "dir": "~/.claude", "email": "you@example.com" },
    "work":     { "dir": "~/.hydra/profiles/work", "email": "you@work.example", "disabled": true }
  }
}
```

A disabled profile stays signed in and shows in `hydra status`, but is never
auto-picked; `claude work` still launches it explicitly.

The choice is made once per launch. A running session is bound to one account
and cannot hop; when it hits a limit, start a new `claude` and hydra routes you
to the profile with headroom — `claude --resume` picks the transcript straight
back up because sessions are shared between profiles.

## Two machines, zero token sync

`profiles.json` holds names, directories and emails — nothing secret — so it
can live in your dotfiles (`HYDRA_MANIFEST=~/dotfiles/hydra.json`). Tokens
never leave the machine: each laptop signs in to each profile once with
`hydra login <name>`, and `hydra status` shows `not signed in on this machine`
for any profile that laptop hasn't logged into yet.

## How it works

- **Isolation** is Claude Code's own [`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/settings).
  Every profile is a directory with its own `.claude.json` (sign-in session,
  account, per-project trust), its own history, and — on macOS — its own
  Keychain item, named `Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>`.
  `~/.claude` stays the default profile and the canonical home for shared config.
- **Shared config** — `settings.json`, `CLAUDE.md`, `skills/`, `plugins/`,
  `commands/`, `agents/`, `projects/` (sessions) and `history.jsonl` — is
  symlinked from `~/.claude` into every profile, so a change applies
  everywhere. `hydra link` reapplies the links if an update replaces one with
  a real file.
- **Usage** comes from `GET https://api.anthropic.com/api/oauth/usage` with the
  profile's OAuth token — the same call that powers `/usage`. Its `limits[]`
  array carries the 5-hour (`session`), weekly (`weekly_all`) and per-model
  (`weekly_scoped`, `display_name: "Fable"`) windows. hydra also reads the
  snapshot Claude Code itself writes after each session
  (`cachedUsageUtilization`) and uses whichever is newer, so most launches
  need no network call at all.
- **Launch never waits on the network.** `claude` picks from cached numbers
  and starts immediately; stale caches are refreshed in a detached background
  process for the next launch. Polling is floored at 180 s because the
  endpoint rate-limits anything faster.

## Limitations

- The usage endpoint is undocumented; the `limits[]` shape has been stable but
  may change. The parser is tolerant — a missing bucket shows as `-`.
- When an idle profile's access token lapses the usage call returns 401; hydra
  keeps the last numbers (marked `token stale`) and Claude Code refreshes the
  token itself the next time that profile launches. Only an expired *refresh*
  token needs `hydra login <name>`.
- If the same account is used on two machines, each machine's cache only knows
  what it fetched; the reset-time decay keeps it from being pessimistic, and
  the next launch refreshes it.
- User-scope MCP servers (`claude mcp add -s user`) live in `.claude.json`,
  which is per profile — add them under each profile (`claude work mcp add …`),
  or use project scope.
- Claude Code writes settings atomically; if an update ever replaces the
  `settings.json` symlink with a real file, `hydra link --force` restores it.

## Tests

```sh
test/run.sh          # everything
test/run.sh pick     # only tests whose name contains "pick"
```

No dependencies beyond bash, jq and coreutils. Each test runs in a throwaway
sandbox — its own `$HOME`, a fake `claude` and `curl` on `PATH`, a fixed clock
(`HYDRA_NOW`) and file-based credentials (`HYDRA_NO_KEYCHAIN=1`) — so nothing
touches your real profiles, Keychain or the network. CI runs the suite on
macOS and Ubuntu.

## Credits

The Keychain naming and endpoint behaviour were confirmed against
[claude-swap](https://github.com/realiti4/claude-swap) and
[clauth](https://github.com/uwuclxdy/clauth), which are fuller-featured
switchers (daemons, dashboards, threshold rotation) if you want more than a
launcher.

MIT.
