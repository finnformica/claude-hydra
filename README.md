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
Optionally, hydra can also stand in for the `claude` *binary* on PATH, so that
editors and scripts running `claude -p` are routed too (see the shim below).

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

### Routing every launcher: the shim

The install above defines a `claude` shell *function*, so only launches typed
into your shell are routed. Anything that spawns the `claude` binary directly —
an editor integration, a script running `claude -p …`, another tool — lands on
the default profile. To route those as well, install hydra's shim:

```sh
~/.local/share/claude-hydra/install.sh --shim
exec $SHELL
hydra doctor                     # confirms the shim is what a bare `claude` runs
```

The shim is a `claude` at `~/.hydra/bin/claude` (`$HYDRA_HOME/bin`) that runs
`hydra exec "$@"`. It *shadows* the real binary rather than replacing it:
`~/.local/bin/claude` is never touched, `hydra.sh` puts `~/.hydra/bin` first on
PATH for every shell (the installer adds an `export PATH=…` line to your rc as
well), and on each launch hydra finds the real binary afresh — the first
`claude` on PATH that is not its own shim — and execs it by path. Claude Code's
updater can rewrite `~/.local/bin/claude` whenever it likes; the shim stays
where it is and the next launch runs the new version. Nothing is pinned, so
nothing goes stale.

Launchers that do not read your shell rc — a systemd unit, a launchd agent, an
editor started from the Dock — need `~/.hydra/bin` ahead of the real binary in
*their* PATH too:

```ini
# systemd: ~/.config/systemd/user/something.service
Environment=PATH=%h/.hydra/bin:%h/.local/bin:/usr/local/bin:/usr/bin:/bin
```

`hydra doctor` reports whether the shim is installed, whether `~/.hydra/bin`
comes before the directory holding the real binary on PATH, which binary hydra
would exec right now and that it is not the shim itself; it exits non-zero with
a one-line fix for anything wrong. `hydra status` also prints one warning line
on stderr when the shim is installed but a direct `claude` would bypass it, so
the silent case is never silent. `install.sh --unshim` removes the shim and the
PATH line; both directions are idempotent, and `--shim` migrates a machine that
used the previous layout (the shim in place of `~/.local/bin/claude`, with a
`claude.hydra-bak` beside it), restoring the original and printing what it did.

An explicit `CLAUDE_CONFIG_DIR` in the environment still bypasses routing
entirely; that is how a caller pins a profile. Headless callers get a clean
stderr: the routing hint is only printed when stderr is a terminal. If the
shim is ever launched by hydra itself it stops with exit 70 instead of looping.

## Commands

| | |
|---|---|
| `hydra add <name> [--existing \| --dir PATH] [--no-login]` | new profile; `--existing` registers `~/.claude` itself |
| `hydra login <name>` | sign in, or sign in again when a token has expired |
| `hydra remove <name> [--keep-files]` | delete the profile, its Keychain entry and its directory |
| `hydra rename <old> <new>` | relabel a profile; its sign-in is untouched |
| `hydra disable <name>` · `hydra enable <name>` | keep a profile signed in but out of the rotation (`claude <name>` still works) |
| `hydra list` | profiles and their config dirs |
| `hydra status [--cached\|--force] [--json]` | usage table; refreshes anything older than 3 minutes. `--json` prints the same rows (every profile, all three windows, plus `state`) as one JSON document for scripts |
| `hydra refresh [names…] [--force]` | fetch usage now |
| `hydra pick [--json] [--model M]` | which profile a bare `claude` (or `claude --model M`) would use right now |
| `hydra link [names…] [--force]` | (re)apply the shared-config symlinks |
| `hydra dir <name>` · `hydra has <name>` | plumbing for scripts |
| `hydra exec [profile] [claude args…]` | what the `claude` shell function and the shim call |
| `hydra <profile> [claude args…]` | shorthand for `hydra exec <profile> …` |
| `hydra bin [PATH \| --unset]` | the real `claude` binary hydra execs, found on PATH at every launch; `PATH` pins one instead (it will not follow updates), `--unset` drops the pin |
| `hydra doctor` | check the shim: installed, first on PATH, and what a launch would actually run; non-zero with a fix per finding |

Tab completion (zsh and bash) comes with `hydra.sh`: `hydra <Tab>` offers
commands and profiles, `hydra login <Tab>` and `claude <Tab>` offer profiles.

The one-line routing hint is printed only when stderr is a terminal, so a
script capturing stderr never sees it; `HYDRA_QUIET=1` always suppresses it and
`HYDRA_QUIET=0` always prints it. `HYDRA_MODEL=opus` scores launches for that
model when no `--model` is passed. `HYDRA_CLAUDE_BIN` pins the real binary for
one invocation (it beats `claude_bin` in the manifest, which beats the PATH
search). `HYDRA_HOME` (default `~/.hydra`) and `HYDRA_MANIFEST` (default
`$HYDRA_HOME/profiles.json`) move the state.

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

An optional `claude_bin` (set with `hydra bin PATH`) pins the binary hydra
execs; it is machine-specific and does not follow Claude Code updates, so leave
it unset unless you need it — the default is the first `claude` on PATH that is
not hydra's own shim, found at every launch. A pin that does not run on this
machine is ignored.

A disabled profile stays signed in and shows in `hydra status` (its usage is
still refreshed there, table and `--json` alike), but is never auto-picked;
`claude work` still launches it explicitly.

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
- **The real binary is always exec'd by path**, never by the name `claude`,
  and found at every launch: the first `claude` on PATH that is not the shim
  (the shim carries a marker in its header). `HYDRA_CLAUDE_BIN` and
  `claude_bin` in the manifest are explicit pins on top of that. The shim
  lives in `~/.hydra/bin`, ahead of the real binary on PATH, so an update that
  rewrites `~/.local/bin/claude` changes nothing for hydra. If the shim ever
  finds itself launched by hydra it stops with an error instead of looping.

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
- The shim only routes launchers whose PATH has `~/.hydra/bin` ahead of the
  real binary. Shells get that from `hydra.sh`; anything else needs it set
  explicitly, and `hydra doctor` tells you when it is not.

## Tests

```sh
test/run.sh          # everything
test/run.sh pick     # only tests whose name contains "pick"
```

No dependencies beyond bash, jq and coreutils. Each test runs in a throwaway
sandbox — its own `$HOME`, a fake `claude` and `curl` on `PATH`, a fixed clock
(`HYDRA_NOW`) and file-based credentials (`HYDRA_NO_KEYCHAIN=1`) — so nothing
touches your real profiles, Keychain or the network. The shim tests install it
into the sandbox and simulate Claude Code's updater rewriting the binary
underneath it. CI runs the suite on macOS and Ubuntu.

## Credits

The Keychain naming and endpoint behaviour were confirmed against
[claude-swap](https://github.com/realiti4/claude-swap) and
[clauth](https://github.com/uwuclxdy/clauth), which are fuller-featured
switchers (daemons, dashboards, threshold rotation) if you want more than a
launcher.

MIT.
