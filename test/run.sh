#!/usr/bin/env bash
# hydra test suite. Needs bash 3.2+, jq and coreutils — nothing else.
#
#   test/run.sh            run everything
#   test/run.sh pick       run tests whose name contains "pick"
#
# Every test gets a fresh sandbox: its own HOME (so ~/.claude and ~/.claude.json
# are fakes), its own HYDRA_HOME, a fake `claude` and a fake `curl` on PATH, a
# fixed clock, and file-based credentials instead of the Keychain.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HYDRA="$ROOT/hydra"
FILTER="${1:-}"
ORIG_PATH="$PATH"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; N=0

# ---------------------------------------------------------------- harness

ok()   { N=$((N + 1)); PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$N" "$1"; }
fail() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf 'not ok %d - %s\n    # %s\n' "$N" "$1" "$2"; }

assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
assert_contains()     { case "$3" in *"$2"*) ok "$1" ;; *) fail "$1" "expected to contain [$2] in [$3]" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) fail "$1" "did not expect [$2] in [$3]" ;; *) ok "$1" ;; esac; }
assert_ok()           { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else fail "$1" "command failed: ${*:2}"; fi; }
assert_fails()        { if "${@:2}" >/dev/null 2>&1; then fail "$1" "command unexpectedly succeeded: ${*:2}"; else ok "$1"; fi; }
assert_link()         { if [ -L "$2" ] && [ "$(readlink "$2")" = "$3" ]; then ok "$1"; else fail "$1" "$2 is not a link to $3"; fi; }
skip()                { N=$((N + 1)); PASS=$((PASS + 1)); printf 'ok %d - %s # SKIP %s\n' "$N" "$1" "$2"; }

# `test "name"` — starts a test if it matches the filter; returns 1 to skip.
test() {
  case "$1" in *"$FILTER"*) ;; *) return 1 ;; esac
  printf '# %s\n' "$1"
  sandbox
}

NOW=1800000000 # a fixed "now"; resets default to well after it

sandbox() {
  SB="$TMP/sb$N$RANDOM"
  mkdir -p "$SB/home/.claude/skills" "$SB/bin" "$SB/home/.hydra"
  export HOME="$SB/home" HYDRA_HOME="$SB/home/.hydra" HYDRA_NO_KEYCHAIN=1 HYDRA_QUIET=1 HYDRA_NOW=$NOW
  unset HYDRA_MANIFEST HYDRA_MODEL CLAUDE_CONFIG_DIR
  export FAKE_LOG="$SB/fake.log" FAKE_CURL_CODE=200 FAKE_CURL_EXIT=0 FAKE_CURL_BODY="$SB/usage.json" FAKE_EMAIL="who@example.com"
  usage 0 0 0 >"$FAKE_CURL_BODY"
  printf '{"model":"claude-fable-5-1[1m]"}' >"$HOME/.claude/settings.json"
  printf '# global\n' >"$HOME/.claude/CLAUDE.md"

  # Fake claude: prints the config dir and args; `auth login` writes a fake sign-in.
  cat >"$SB/bin/claude" <<'EOF'
#!/bin/sh
printf 'claude %s\n' "$*" >>"$FAKE_LOG"
if [ "$1" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then cfg="$dir/.claude.json"; else cfg="$HOME/.claude.json"; fi
  printf '{"claudeAiOauth":{"accessToken":"tok-%s","expiresAt":1}}' "$FAKE_EMAIL" >"$dir/.credentials.json"
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$FAKE_EMAIL" >"$cfg"
  exit 0
fi
printf 'dir=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
EOF
  # Fake curl: copies FAKE_CURL_BODY to -o, prints FAKE_CURL_CODE, logs its args.
  cat >"$SB/bin/curl" <<'EOF'
#!/bin/sh
printf 'curl %s\n' "$*" >>"$FAKE_LOG"
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
[ "$FAKE_CURL_EXIT" = 0 ] || exit "$FAKE_CURL_EXIT"
cp "$FAKE_CURL_BODY" "$out"
printf '%s' "$FAKE_CURL_CODE"
EOF
  chmod +x "$SB/bin/claude" "$SB/bin/curl"
  export PATH="$SB/bin:$ORIG_PATH"
}

# usage <5h%> <weekly%> <fable%> [5h resets_at] [weekly resets_at] → a /api/oauth/usage body
usage() {
  local s=$1 w=$2 f=$3 sr="${4:-2099-01-01T00:00:00.123456+00:00}" wr="${5:-2099-01-02T00:00:00+00:00}"
  cat <<EOF
{"five_hour":{"utilization":$s,"resets_at":"$sr","locked_reason":${LOCKED:-null}},
 "seven_day":{"utilization":$w,"resets_at":"$wr","locked_reason":null},
 "seven_day_opus":null,
 "limits":[
  {"kind":"session","group":"session","percent":$s,"severity":"normal","resets_at":"$sr","scope":null,"is_active":true},
  {"kind":"weekly_all","group":"weekly","percent":$w,"severity":"normal","resets_at":"$wr","scope":null,"is_active":false},
  {"kind":"weekly_scoped","group":"weekly","percent":$f,"severity":"normal","resets_at":"$wr","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}
EOF
}

# add <name> [email] [add args…]: add + fake sign-in
add() { local n=$1 e=${2:-$1@example.com}; shift; shift 2>/dev/null || true; FAKE_EMAIL=$e "$HYDRA" add "$n" "$@" >/dev/null 2>&1; }

# set_usage <name> <5h> <weekly> <fable> [resets…]: serve these numbers and fetch them into the cache
set_usage() { local n=$1; shift; usage "$@" >"$SB/u-$n.json"; FAKE_CURL_BODY="$SB/u-$n.json" "$HYDRA" refresh --force "$n" >/dev/null; }

cache() { cat "$HYDRA_HOME/cache/$1.json"; }
real() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"; }   # what hydra bin prints (macOS: /var → /private/var)

# shim_install: install.sh --shim into the sandbox's own bin dir, then put that dir first on PATH
# so that `claude` by name is the shim; the fake claude in $SB/bin stays the "real" binary behind it.
shim_install() { mkdir -p "$SB/lbin"; HYDRA_BIN_DIR="$SB/lbin" HYDRA_RC="$SB/rc" "$ROOT/install.sh" "$@" 2>&1; }
shim_on()      { shim_install --shim >/dev/null || fail "install.sh --shim" "failed"; export PATH="$SB/lbin:$PATH"; }

# with_tty <shell command>: run it on a pseudo-terminal (stderr included) and print what appeared there.
has_tty()  { command -v script >/dev/null 2>&1; }
with_tty() { if script --version >/dev/null 2>&1; then script -qec "$1" /dev/null; else script -q /dev/null bash -c "$1"; fi; }

# tool_path: a PATH holding every tool hydra and install.sh need, and nothing called claude.
tool_path() {
  local t p
  mkdir -p "$SB/toolbin"
  for t in env bash sh jq cat cut tr awk date mv rm mkdir head grep uname readlink ln chmod dirname basename ls cp wc sed shasum sha256sum; do
    p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$SB/toolbin/$t"
  done
  ln -sf "$SB/bin/curl" "$SB/toolbin/curl"
  printf '%s' "$SB/toolbin"
}
manifest() { cat "$HYDRA_HOME/profiles.json"; }
pick() { "$HYDRA" pick "$@"; }
pickj() { local f=$1; shift; "$HYDRA" pick --json "$@" | jq -r "$f"; }
statusj() { local f=$1; shift; "$HYDRA" status --json "$@" | jq -r "$f"; }
curl_calls() { local n; n=$(grep -c '^curl' "$FAKE_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }

# ---------------------------------------------------------------- profiles

if test "add --existing registers ~/.claude without creating anything"; then
  add personal who@example.com --existing
  assert_eq "dir is stored as ~/.claude" "~/.claude" "$(manifest | jq -r .profiles.personal.dir)"
  assert_eq "email is recorded from ~/.claude.json" "who@example.com" "$(manifest | jq -r .profiles.personal.email)"
  assert_eq "no profile dir is created" "" "$(ls "$HYDRA_HOME/profiles" 2>/dev/null)"
  assert_eq "dir resolves to the real path" "$HOME/.claude" "$("$HYDRA" dir personal)"
fi

if test "add creates a profile dir with shared config linked in"; then
  add work
  d="$HYDRA_HOME/profiles/work"
  assert_eq "stored with ~ for portability" "~/.hydra/profiles/work" "$(manifest | jq -r .profiles.work.dir)"
  assert_link "settings.json is linked" "$d/settings.json" "$HOME/.claude/settings.json"
  assert_link "CLAUDE.md is linked" "$d/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  assert_link "skills/ is linked" "$d/skills" "$HOME/.claude/skills"
  assert_link "projects/ is created in ~/.claude and linked" "$d/projects" "$HOME/.claude/projects"
  assert_eq "history.jsonl absent in ~/.claude is skipped" "" "$(ls "$d/history.jsonl" 2>/dev/null)"
  assert_eq "sign-in ran inside the profile dir" "1" "$(grep -c 'claude auth login' "$FAKE_LOG")"
  assert_eq "credentials live in the profile" "1" "$(ls "$d/.credentials.json" | wc -l | tr -d ' ')"
  assert_eq "email recorded from the profile's .claude.json" "work@example.com" "$(manifest | jq -r .profiles.work.email)"
fi

if test "add --dir uses a custom directory and strips a trailing slash"; then
  add w "" --dir "$SB/elsewhere/"
  assert_eq "trailing slash stripped" "$SB/elsewhere" "$("$HYDRA" dir w)"
  assert_link "still linked" "$SB/elsewhere/settings.json" "$HOME/.claude/settings.json"
fi

if test "add --no-login skips the sign-in"; then
  add w "" --no-login
  assert_eq "no login ran" "" "$(grep 'auth login' "$FAKE_LOG" 2>/dev/null)"
  assert_contains "status says so" "not signed in on this machine" "$("$HYDRA" status --cached)"
fi

if test "add rejects unusable names"; then
  for bad in mcp auth update add exec pick bin auto best Work -x "a b" ""; do
    assert_fails "rejects '$bad'" "$HYDRA" add "$bad" --no-login
  done
  add w "" --no-login
  assert_fails "rejects a duplicate" "$HYDRA" add w --no-login
  assert_ok "accepts dashes, digits and underscores" "$HYDRA" add my-2nd_acct --no-login
fi

if test "rename keeps the dir and sign-in, moves the cache"; then
  add w; set_usage w 10 20 30
  "$HYDRA" rename w renamed >/dev/null 2>&1
  assert_eq "old key gone" "null" "$(manifest | jq -r .profiles.w)"
  assert_eq "dir unchanged" "~/.hydra/profiles/w" "$(manifest | jq -r .profiles.renamed.dir)"
  assert_eq "cache moved" "10" "$(cache renamed | jq '.limits[0].percent')"
  assert_eq "still signed in" "ok" "$("$HYDRA" status --cached | awk '/renamed/{print $NF}')"
  assert_fails "rename to a reserved name fails" "$HYDRA" rename renamed mcp
  assert_fails "rename to an existing name fails" "$HYDRA" rename renamed renamed
fi

if test "remove deletes only what hydra owns"; then
  add personal "" --existing; add w; add out "" --dir "$SB/out"
  set_usage w 1 1 1
  "$HYDRA" remove w >/dev/null 2>&1
  assert_eq "profile dir under ~/.hydra deleted" "" "$(ls -d "$HYDRA_HOME/profiles/w" 2>/dev/null)"
  assert_eq "cache deleted" "" "$(ls "$HYDRA_HOME/cache/w.json" 2>/dev/null)"
  assert_eq "manifest entry gone" "null" "$(manifest | jq -r .profiles.w)"
  "$HYDRA" remove out >/dev/null 2>&1
  assert_eq "a --dir outside ~/.hydra is left in place" "$SB/out" "$(ls -d "$SB/out")"
  assert_eq "…but its credentials are cleared" "" "$(ls "$SB/out/.credentials.json" 2>/dev/null)"
  "$HYDRA" remove personal >/dev/null 2>&1
  assert_eq "~/.claude sign-in is never touched" "1" "$(ls "$HOME/.claude/.credentials.json" | wc -l | tr -d ' ')"
  assert_eq "nothing left" "0" "$(manifest | jq '.profiles | length')"
fi

if test "remove --keep-files keeps the directory"; then
  add w; "$HYDRA" remove w --keep-files >/dev/null 2>&1
  assert_eq "dir kept" "$HYDRA_HOME/profiles/w" "$(ls -d "$HYDRA_HOME/profiles/w")"
fi

if test "link repairs drift"; then
  add w --no-login; d="$HYDRA_HOME/profiles/w"
  rm "$d/settings.json"; printf '{"model":"x"}' >"$d/settings.json"   # an update replaced the link with a file
  rm "$d/skills"; ln -s /nowhere "$d/skills"                             # a link pointing elsewhere
  out=$("$HYDRA" link w 2>&1)
  assert_contains "reports the real file" "settings.json is a real file" "$out"
  assert_link "wrong link is repointed" "$d/skills" "$HOME/.claude/skills"
  "$HYDRA" link w --force >/dev/null 2>&1
  assert_link "--force relinks the file" "$d/settings.json" "$HOME/.claude/settings.json"
  assert_eq "…and keeps the old copy" '{"model":"x"}' "$(cat "$d/settings.json.hydra-bak")"
fi

if test "a new profile skips Claude's first-run wizard"; then
  printf '{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.0","theme":"dark","numStartups":9,"oauthAccount":{"emailAddress":"me@example.com"}}' >"$HOME/.claude.json"
  add w
  cfg="$HYDRA_HOME/profiles/w/.claude.json"
  assert_eq "onboarding marker copied" "true" "$(jq .hasCompletedOnboarding "$cfg")"
  assert_eq "theme copied" "dark" "$(jq -r .theme "$cfg")"
  assert_eq "unrelated keys are not copied" "null" "$(jq .numStartups "$cfg")"
  assert_eq "the profile's own account is kept" "w@example.com" "$(jq -r .oauthAccount.emailAddress "$cfg")"
  jq '.theme = "light"' "$cfg" >"$SB/c" && mv "$SB/c" "$cfg"
  "$HYDRA" link w >/dev/null 2>&1
  assert_eq "link seeds but never overwrites" "light" "$(jq -r .theme "$cfg")"
  add old "" --no-login; rm -f "$HYDRA_HOME/profiles/old/.claude.json"
  "$HYDRA" link old >/dev/null 2>&1
  assert_eq "link seeds a profile with no state file at all" "true" "$(jq .hasCompletedOnboarding "$HYDRA_HOME/profiles/old/.claude.json")"
  assert_eq "default profile untouched" "9" "$(jq .numStartups "$HOME/.claude.json")"
fi

if test "enable/disable"; then
  add a; add b; set_usage a 50 0 0; set_usage b 10 0 0
  assert_eq "b is freshest" b "$(pick)"
  "$HYDRA" disable b >/dev/null 2>&1
  assert_eq "disabled b is skipped" a "$(pick)"
  assert_contains "list marks it" "disabled" "$("$HYDRA" list | grep '^b ')"
  assert_contains "status marks it" "disabled" "$("$HYDRA" status --cached | grep '^b ')"
  : >"$FAKE_LOG"; "$HYDRA" refresh --force >/dev/null
  assert_eq "refresh skips disabled profiles" "1" "$(curl_calls)"
  "$HYDRA" refresh --force b >/dev/null
  assert_eq "…unless named" "2" "$(curl_calls)"
  out=$("$HYDRA" exec b x)
  assert_contains "claude b still launches it" "dir=$HYDRA_HOME/profiles/b" "$out"
  set_usage a 50 0 0; set_usage b 10 0 0
  "$HYDRA" enable b >/dev/null 2>&1
  assert_eq "enabled again" b "$(pick)"
fi

# ---------------------------------------------------------------- usage fetch

if test "fetch sends the token and a first-party User-Agent"; then
  add w; set_usage w 1 2 3
  assert_contains "bearer token" "Authorization: Bearer tok-w@example.com" "$(cat "$FAKE_LOG")"
  assert_contains "oauth beta header" "anthropic-beta: oauth-2025-04-20" "$(cat "$FAKE_LOG")"
  assert_contains "user agent from claude --version" "User-Agent: claude-code/9.9.9" "$(cat "$FAKE_LOG")"
  assert_eq "cache records the three windows" "1 2 3" "$(cache w | jq -r '[.limits[].percent] | join(" ")')"
  assert_eq "fetched_at is now" "$NOW" "$(cache w | jq .fetched_at)"
fi

if test "fetch failures keep the last good numbers"; then
  add w; set_usage w 40 0 0
  FAKE_CURL_CODE=429 "$HYDRA" refresh --force w | grep -q rate-limited && ok "429 reported" || fail "429 reported" "no"
  assert_eq "429 keeps cache" "40" "$(cache w | jq '.limits[0].percent')"
  FAKE_CURL_EXIT=7 "$HYDRA" refresh --force w | grep -q offline && ok "offline reported" || fail "offline reported" "no"
  assert_eq "offline keeps cache" "40" "$(cache w | jq '.limits[0].percent')"
  printf 'not json' >"$SB/bad.json"
  FAKE_CURL_BODY="$SB/bad.json" "$HYDRA" refresh --force w | grep -q bad-response && ok "bad body reported" || fail "bad body reported" "no"
  assert_eq "bad body keeps cache" "40" "$(cache w | jq '.limits[0].percent')"
  FAKE_CURL_CODE=401 "$HYDRA" refresh --force w >/dev/null
  assert_eq "401 keeps numbers" "40" "$(cache w | jq '.limits[0].percent')"
  assert_eq "401 marks the token stale" "stale" "$(cache w | jq -r .auth)"
  assert_contains "status explains" "token stale" "$("$HYDRA" status --cached)"
  assert_eq "a stale profile still ranks" w "$(pick)"
fi

if test "401 with no cache yet"; then
  add w
  FAKE_CURL_CODE=401 "$HYDRA" refresh --force w >/dev/null
  assert_eq "stale placeholder written" "stale" "$(cache w | jq -r .auth)"
  assert_contains "status: no numbers, stale" "token stale" "$("$HYDRA" status --cached)"
fi

if test "refresh honours the 180 s floor"; then
  add w; set_usage w 1 1 1
  out=$("$HYDRA" refresh w); assert_contains "fresh data is not refetched" "fresh" "$out"
  out=$(HYDRA_NOW=$((NOW + 179)) "$HYDRA" refresh w); assert_contains "179 s: still fresh" "fresh" "$out"
  out=$(HYDRA_NOW=$((NOW + 180)) "$HYDRA" refresh w); assert_contains "180 s: refetched" "ok" "$out"
  out=$("$HYDRA" refresh --force w); assert_contains "--force always fetches" "ok" "$out"
fi

if test "a signed-out profile is not fetched"; then
  add w "" --no-login
  assert_contains "reports no-auth" "no-auth" "$("$HYDRA" refresh --force w)"
  assert_eq "no request made" "0" "$(curl_calls)"
fi

if test "the newer of hydra's cache and Claude's own snapshot wins"; then
  add w; set_usage w 10 10 10
  # Claude wrote a fresher snapshot after a session
  jq --argjson at $(( (NOW + 60) * 1000 )) --argjson u "$(usage 70 5 5)" \
    '.cachedUsageUtilization = {fetchedAtMs: $at, utilization: $u}' "$HYDRA_HOME/profiles/w/.claude.json" >"$SB/c.json"
  mv "$SB/c.json" "$HYDRA_HOME/profiles/w/.claude.json"
  assert_eq "Claude's snapshot is used" "70" "$(pickj .s)"
  assert_eq "source says so" "claude" "$(pickj .source)"
  # …but an older one loses
  jq '.cachedUsageUtilization.fetchedAtMs = 1000' "$HYDRA_HOME/profiles/w/.claude.json" >"$SB/c.json"
  mv "$SB/c.json" "$HYDRA_HOME/profiles/w/.claude.json"
  assert_eq "hydra's newer cache is used" "10" "$(pickj .s)"
fi

if test "resets_at formats all parse"; then
  add w
  for fmt in "2099-01-01T00:00:00.123456+00:00" "2099-01-01T00:00:00+00:00" "2099-01-01T00:00:00Z"; do
    set_usage w 0 0 0 "$fmt"
    assert_eq "parses $fmt" "4070908800" "$(pickj .session.resets)"
  done
fi

# ---------------------------------------------------------------- picking

if test "pick: lowest max(5h, Fable) wins"; then
  add a; add b; add c
  set_usage a 30 0 10; set_usage b 10 0 40; set_usage c 20 0 20
  assert_eq "c (max 20) beats a (30) and b (40)" c "$(pick)"
  assert_eq "score reported" "20" "$(pickj .score)"
fi

if test "pick: ties within 5 points go to the lower weekly, then soonest 5h reset"; then
  add a; add b; add c
  set_usage a 22 60 0; set_usage b 20 30 0; set_usage c 24 30 0 "2099-01-01T00:00:00Z"
  set_usage b 20 30 0 "2099-06-01T00:00:00Z"
  assert_eq "same 5-point band, lower weekly wins (b/c over a)…" c "$(pick)"
  set_usage c 24 30 0 "2099-06-01T00:00:00Z"; set_usage b 20 30 0 "2099-01-01T00:00:00Z"
  assert_eq "…then soonest 5h reset" b "$(pick)"
fi

if test "pick: the threshold sets exhausted profiles aside"; then
  add a; add b
  set_usage a 5 92 5; set_usage b 50 0 50
  assert_eq "a at weekly 92 is exhausted; b wins despite a's lower score" b "$(pick)"
  assert_contains "status says exhausted" "exhausted" "$("$HYDRA" status --cached | grep '^a ')"
  jq '.threshold = 95' "$HYDRA_HOME/profiles.json" >"$SB/m" && mv "$SB/m" "$HYDRA_HOME/profiles.json"
  assert_eq "raising the threshold brings a back" a "$(pick)"
  set_usage a 5 0 90
  assert_eq "Fable at the threshold is exhausted too" b "$(HYDRA_NOW=$NOW pick)"
fi

if test "pick: when everything is exhausted, the least-bad one is still returned"; then
  add a; add b
  set_usage a 99 0 0; set_usage b 91 0 0
  assert_eq "b is least bad" b "$(pick)"
  assert_eq "flagged exhausted" "true" "$(pickj .exhausted)"
  assert_contains "exec warns" "everything is near its limit" "$(HYDRA_QUIET=0 "$HYDRA" exec x 2>&1 >/dev/null)"
fi

if test "pick: a locked account is set aside"; then
  add a; add b
  LOCKED='"some_reason"' set_usage a 0 0 0; set_usage b 50 0 0
  assert_eq "unlocked b wins" b "$(pick)"
  assert_contains "status: locked" "locked" "$("$HYDRA" status --cached | grep '^a ')"
fi

if test "pick: signed-out profiles are ignored"; then
  add a "" --no-login; add b; set_usage b 80 0 0
  assert_eq "only b is eligible" b "$(pick)"
  "$HYDRA" remove b >/dev/null 2>&1
  assert_fails "no signed-in profile at all" "$HYDRA" pick
fi

if test "pick: a window that has reset counts as empty"; then
  add a; add b
  set_usage a 90 0 0 "2000-01-01T00:00:00Z"   # 5h window long since reset
  set_usage b 10 0 0
  assert_eq "a's stale 90% is treated as 0" a "$(pick)"
  set_usage a 90 0 80 "2099-01-01T00:00:00Z" "2000-01-01T00:00:00Z"   # weekly reset
  assert_eq "reset weekly/Fable count as 0 (but 5h 90 is real)" b "$(pick)"
fi

if test "pick: a 5h window resetting within the grace period counts as empty"; then
  add a; add b
  soon=$(date -u -r $((NOW + 540)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW + 540)) +%Y-%m-%dT%H:%M:%SZ)
  later=$(date -u -r $((NOW + 660)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW + 660)) +%Y-%m-%dT%H:%M:%SZ)
  set_usage a 80 0 0 "$soon"; set_usage b 10 0 0
  assert_eq "9 min to reset → a counts as 0 and wins" a "$(pick)"
  set_usage a 80 0 0 "$later"
  assert_eq "11 min to reset → a's 80% is real" b "$(pick)"
fi

if test "pick: weights"; then
  add a; add b
  set_usage a 40 0 20; set_usage b 20 0 40
  assert_eq "equal weights: tie band → equal weekly → first by reset" a "$(pick)"
  jq '.weights.fable = 2' "$HYDRA_HOME/profiles.json" >"$SB/m" && mv "$SB/m" "$HYDRA_HOME/profiles.json"
  assert_eq "Fable weighted ×2: a (40 vs 40) beats b (20 vs 80)" a "$(pick)"
  jq '.weights.fable = 1 | .weights.session = 3' "$HYDRA_HOME/profiles.json" >"$SB/m" && mv "$SB/m" "$HYDRA_HOME/profiles.json"
  assert_eq "session weighted ×3: b (60) beats a (120)" b "$(pick)"
fi

if test "pick: model intent"; then
  add a; add b
  set_usage a 10 20 90; set_usage b 30 70 10    # a: Fable spent; b: weekly heavy
  assert_eq "Fable session → b" b "$(pick)"
  assert_eq "opus session → a (Fable ignored, max(10,20)=20 < max(30,70))" a "$(pick --model opus)"
  assert_eq "--model=opus form" a "$(pick --model=opus)"
  assert_eq "full model id containing opus" a "$(pick --model claude-opus-5)"
  assert_eq "HYDRA_MODEL env" a "$(HYDRA_MODEL=sonnet pick)"
  assert_eq "--model beats HYDRA_MODEL" b "$(HYDRA_MODEL=opus pick --model fable)"
  printf '{"model":"opus"}' >"$HOME/.claude/settings.json"
  assert_eq "settings.json model is the default" a "$(pick)"
  printf '{}' >"$HOME/.claude/settings.json"
  assert_eq "no model anywhere → manifest default_model (fable)" b "$(pick)"
  jq '.default_model = "opus"' "$HYDRA_HOME/profiles.json" >"$SB/m" && mv "$SB/m" "$HYDRA_HOME/profiles.json"
  assert_eq "manifest default_model honoured" a "$(pick)"
  assert_eq "Fable is null in a non-Fable pick" "null" "$(pickj .f --model opus)"
fi

if test "pick: a profile with no data yet is fetched synchronously"; then
  add a; add b; set_usage a 50 0 0
  rm -f "$HYDRA_HOME/cache/b.json"; usage 5 0 0 >"$FAKE_CURL_BODY"
  assert_eq "b fetched on demand and wins" b "$(pick)"
fi

if test "pick: a profile whose fetch failed ranks after known ones"; then
  add a; add b; set_usage a 50 0 0
  rm -f "$HYDRA_HOME/cache/b.json"
  assert_eq "b (unknown) loses to a (known)" a "$(FAKE_CURL_EXIT=7 pick)"
fi

# ---------------------------------------------------------------- exec / the claude wrapper

if test "exec: passthrough cases"; then
  add personal "" --existing; add w; set_usage w 0 0 0; set_usage personal 50 0 0
  assert_contains "explicit CLAUDE_CONFIG_DIR is respected" "dir=/x" "$(CLAUDE_CONFIG_DIR=/x "$HYDRA" exec foo)"
  assert_contains "claude subcommand: mcp" "dir=<unset>" "$("$HYDRA" exec mcp list)"
  assert_contains "claude subcommand: auth" "dir=<unset>" "$("$HYDRA" exec auth status)"
  assert_contains "--version" "9.9.9" "$("$HYDRA" exec --version)"
  assert_contains "--help" "dir=<unset>" "$("$HYDRA" exec --help)"
  assert_eq "no hint for passthrough" "" "$(HYDRA_QUIET=0 "$HYDRA" exec mcp list 2>&1 >/dev/null)"
fi

if test "exec: routes a bare launch and keeps every argument"; then
  add personal "" --existing; add w; set_usage w 0 0 0; set_usage personal 50 0 0
  out=$("$HYDRA" exec -p "two words" --resume --model opus)
  assert_contains "routed to w" "dir=$HYDRA_HOME/profiles/w" "$out"
  assert_contains "args intact (1)" "arg=[-p]" "$out"
  assert_contains "args intact (2)" "arg=[two words]" "$out"
  assert_contains "args intact (3)" "arg=[--model]" "$out"
  out=$(HYDRA_QUIET=0 "$HYDRA" exec -p hi 2>&1 >/dev/null)
  assert_contains "hint names the profile" "hydra → w" "$out"
  assert_contains "hint shows 5h" "5h 0%" "$out"
  assert_contains "hint shows Fable" "Fable 0%" "$out"
  out=$(HYDRA_QUIET=0 "$HYDRA" exec --model opus 2>&1 >/dev/null)
  assert_contains "opus hint says Fable is ignored" "(opus: Fable window ignored)" "$out"
  assert_eq "HYDRA_QUIET silences the hint" "" "$(HYDRA_QUIET=1 "$HYDRA" exec -p hi 2>&1 >/dev/null)"
fi

if test "exec: a named profile"; then
  add personal "" --existing; add w; set_usage w 90 90 90; set_usage personal 0 0 0
  assert_contains "claude w → w even though it is worse" "dir=$HYDRA_HOME/profiles/w" "$("$HYDRA" exec w --resume)"
  assert_contains "the name is consumed" "arg=[--resume]" "$("$HYDRA" exec w --resume)"
  assert_not_contains "…and not passed on" "arg=[w]" "$("$HYDRA" exec w --resume)"
  assert_contains "the default profile leaves CLAUDE_CONFIG_DIR unset" "dir=<unset>" "$("$HYDRA" exec personal)"
  assert_contains "claude w mcp add routes the subcommand too" "dir=$HYDRA_HOME/profiles/w" "$("$HYDRA" exec w mcp add x)"
  assert_contains "hydra <profile> shorthand" "dir=$HYDRA_HOME/profiles/w" "$("$HYDRA" w --resume)"
fi

if test "exec: no profiles configured → plain claude"; then
  assert_contains "passthrough" "dir=<unset>" "$("$HYDRA" exec -p hi)"
  assert_fails "unknown command still errors" "$HYDRA" bogus
fi

if test "exec: nobody signed in → plain claude with a hint"; then
  add w "" --no-login
  out=$(HYDRA_QUIET=0 "$HYDRA" exec -p hi 2>&1)
  assert_contains "launches anyway" "dir=<unset>" "$out"
  assert_contains "explains" "no signed-in profile" "$out"
fi

if test "exec: refreshes stale data in the background, never in the launch path"; then
  add w; set_usage w 0 0 0
  jq '.fetched_at = 1' "$HYDRA_HOME/cache/w.json" >"$SB/c" && mv "$SB/c" "$HYDRA_HOME/cache/w.json"
  usage 33 0 0 >"$FAKE_CURL_BODY"
  out=$(HYDRA_QUIET=0 "$HYDRA" exec x 2>&1)
  assert_contains "launch used the stale numbers" "5h 0%" "$out"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cache w | jq .fetched_at)" = "$NOW" ] && break; sleep 0.3; done
  assert_eq "cache refreshed afterwards" "33" "$(cache w | jq '.limits[0].percent')"
fi

if test "exec: does not refetch fresh data"; then
  add w; set_usage w 0 0 0; : >"$FAKE_LOG"
  "$HYDRA" exec x >/dev/null; sleep 0.5
  assert_eq "no curl call" "0" "$(curl_calls)"
fi

if test "the claude() shell function wraps the binary"; then
  add w; set_usage w 0 0 0
  out=$(PATH="$ROOT:$PATH" bash -c "source '$ROOT/hydra.sh'; claude -p hi")
  assert_contains "routed via the function" "dir=$HYDRA_HOME/profiles/w" "$out"
  out=$(PATH="$SB/bin:/usr/bin:/bin" bash -c "source '$ROOT/hydra.sh'; claude -p hi")
  assert_contains "without hydra on PATH it falls back to the binary" "dir=<unset>" "$out"
fi

if test "exec: the routing hint only goes to a terminal"; then
  add w; set_usage w 0 0 0
  HYDRA_QUIET= "$HYDRA" exec -p hi 2>"$SB/err" >/dev/null
  assert_eq "stderr captured to a file gets nothing from hydra" "" "$(cat "$SB/err")"
  assert_eq "…the launch still happened" "1" "$(grep -c '^claude -p hi' "$FAKE_LOG")"
  assert_eq "HYDRA_QUIET=1 is quiet even on a pipe" "" "$(HYDRA_QUIET=1 "$HYDRA" exec -p hi 2>&1 >/dev/null)"
  assert_contains "HYDRA_QUIET=0 forces the hint onto a pipe" "hydra → w" "$(HYDRA_QUIET=0 "$HYDRA" exec -p hi 2>&1 >/dev/null)"
  if has_tty; then
    assert_contains "a terminal still gets it" "hydra → w" "$(with_tty "HYDRA_QUIET= '$HYDRA' exec -p hi >/dev/null")"
    assert_not_contains "HYDRA_QUIET=1 silences a terminal too" "hydra" "$(with_tty "HYDRA_QUIET=1 '$HYDRA' exec -p hi >/dev/null")"
  else
    skip "a terminal still gets it" "no script(1) to allocate a pty"
  fi
fi

# ---------------------------------------------------------------- the shim

if test "bin: the real claude is never hydra or its shim"; then
  fake=$(real "$SB/bin/claude")
  assert_eq "first claude on PATH, resolved" "$fake" "$("$HYDRA" bin)"
  mkdir -p "$SB/shimbin"; ln -s "$ROOT/claude-shim" "$SB/shimbin/claude"
  assert_eq "a shim ahead of it on PATH is skipped" "$fake" "$(PATH="$SB/shimbin:$PATH" "$HYDRA" bin)"
  ln -sf "$ROOT/hydra" "$SB/shimbin/claude"
  assert_eq "hydra itself ahead of it is skipped" "$fake" "$(PATH="$SB/shimbin:$PATH" "$HYDRA" bin)"
  assert_fails "HYDRA_CLAUDE_BIN pointing at the shim is refused" env HYDRA_CLAUDE_BIN="$ROOT/claude-shim" "$HYDRA" bin
  assert_fails "HYDRA_CLAUDE_BIN pointing nowhere is refused" env HYDRA_CLAUDE_BIN="$SB/nope" "$HYDRA" bin
  assert_fails "hydra bin PATH refuses the shim" "$HYDRA" bin "$ROOT/claude-shim"
  assert_fails "'bin' is a reserved profile name" "$HYDRA" add bin --no-login
  mkdir -p "$SB/other"; cp "$SB/bin/claude" "$SB/other/claude"
  "$HYDRA" bin "$SB/other/claude" 2>/dev/null
  assert_eq "hydra bin PATH records it resolved" "$(real "$SB/other/claude")" "$(manifest | jq -r .claude_bin)"
  assert_eq "…and the manifest entry wins over PATH" "$(real "$SB/other/claude")" "$("$HYDRA" bin)"
  assert_eq "HYDRA_CLAUDE_BIN beats the manifest" "$fake" "$(HYDRA_CLAUDE_BIN="$SB/bin/claude" "$HYDRA" bin)"
  jq '.claude_bin = "/nowhere/claude"' "$HYDRA_HOME/profiles.json" >"$SB/m" && mv "$SB/m" "$HYDRA_HOME/profiles.json"
  assert_eq "an entry that does not run here falls back to PATH" "$fake" "$("$HYDRA" bin)"
  "$HYDRA" bin --unset 2>/dev/null
  assert_eq "--unset forgets it" "null" "$(manifest | jq -r .claude_bin)"
  assert_fails "no real claude anywhere is a clear failure" env PATH="$SB/shimbin:$(tool_path)" "$HYDRA" bin
  assert_contains "…that says so" "no claude binary on PATH apart from hydra's own shim" "$(PATH="$SB/shimbin:$(tool_path)" "$HYDRA" bin 2>&1)"
fi

if test "shim: claude -p from any launcher is routed to the real binary"; then
  add personal "" --existing; add w; set_usage w 0 0 0; set_usage personal 50 0 0
  shim_on
  assert_link "the claude on PATH is the shim" "$SB/lbin/claude" "$ROOT/claude-shim"
  assert_eq "claude_bin recorded, resolved" "$(real "$SB/bin/claude")" "$(manifest | jq -r .claude_bin)"
  : >"$FAKE_LOG"
  out=$(bash -c 'claude -p "x y" --output-format json' 2>"$SB/err")
  assert_contains "routed to w" "dir=$HYDRA_HOME/profiles/w" "$out"
  assert_contains "args intact (1)" "arg=[-p]" "$out"
  assert_contains "args intact (2)" "arg=[x y]" "$out"
  assert_contains "args intact (3)" "arg=[--output-format]" "$out"
  assert_contains "args intact (4)" "arg=[json]" "$out"
  assert_eq "the real binary ran exactly once — no recursion" "1" "$(grep -c '^claude -p' "$FAKE_LOG")"
  assert_eq "a headless caller sees nothing on stderr" "" "$(cat "$SB/err")"
  set_usage w 60 0 0
  assert_contains "the default profile leaves CLAUDE_CONFIG_DIR unset" "dir=<unset>" "$(bash -c 'claude -p hi')"
  assert_contains "a named profile still works through the shim" "dir=$HYDRA_HOME/profiles/w" "$(bash -c 'claude w -p hi')"
  assert_contains "claude subcommands still pass through" "arg=[list]" "$(bash -c 'claude mcp list')"
  assert_contains "--version too" "9.9.9" "$(bash -c 'claude --version')"
  assert_contains "the shell function and the shim agree" "dir=<unset>" "$(bash -c "source '$ROOT/hydra.sh'; claude -p hi")"
  if has_tty; then
    assert_contains "a terminal gets the hint through the shim" "hydra → personal" "$(with_tty "HYDRA_QUIET= claude -p hi >/dev/null")"
  fi
fi

if test "shim: claude -p --model opus picks by Opus intent"; then
  add a; add b; set_usage a 10 20 90; set_usage b 30 70 10   # a: Fable spent; b: weekly heavy
  shim_on
  assert_contains "Fable session → b" "dir=$HYDRA_HOME/profiles/b" "$(bash -c 'claude -p hi')"
  assert_contains "opus → a, whose spent Fable window is irrelevant" "dir=$HYDRA_HOME/profiles/a" "$(bash -c 'claude -p hi --model opus')"
  assert_contains "--model=opus form" "dir=$HYDRA_HOME/profiles/a" "$(bash -c 'claude --model=opus -p hi')"
  assert_contains "the model argument is passed on" "arg=[opus]" "$(bash -c 'claude -p hi --model opus')"
fi

if test "shim: an explicit CLAUDE_CONFIG_DIR bypasses routing"; then
  add w; set_usage w 0 0 0
  shim_on; : >"$FAKE_LOG"
  out=$(CLAUDE_CONFIG_DIR=/x bash -c 'claude -p hi --output-format json')
  assert_contains "passed through unchanged" "dir=/x" "$out"
  assert_contains "args intact" "arg=[--output-format]" "$out"
  assert_eq "no usage fetch on the way" "0" "$(curl_calls)"
fi

if test "shim: the recursion tripwire stops a shim that resolves to itself"; then
  out=$(bash -c 'HYDRA_LAUNCH_PID=$$ exec "$1" -p hi' _ "$ROOT/claude-shim" 2>&1); rc=$?
  assert_eq "exits 70" "70" "$rc"
  assert_contains "explains" "launched recursively" "$out"
  assert_eq "nothing launched" "" "$(cat "$FAKE_LOG" 2>/dev/null)"
fi

if test "shim: install.sh --shim replaces ~/.local/bin/claude and --unshim puts it back"; then
  # The macOS native layout: ~/.local/bin/claude is a symlink to the versioned binary.
  mkdir -p "$SB/real" "$SB/lbin"; mv "$SB/bin/claude" "$SB/real/claude"; ln -s "$SB/real/claude" "$SB/lbin/claude"
  export PATH="$SB/lbin:$SB/bin:$ORIG_PATH"
  add w; set_usage w 0 0 0
  out=$(shim_install --shim)
  assert_contains "says what it replaced" "replaced $SB/lbin/claude → $SB/real/claude" "$out"
  assert_link "the shim is in place" "$SB/lbin/claude" "$ROOT/claude-shim"
  assert_link "the original link is kept" "$SB/lbin/claude.hydra-bak" "$SB/real/claude"
  assert_eq "claude_bin is the resolved binary, not the replaced link" "$(real "$SB/real/claude")" "$(manifest | jq -r .claude_bin)"
  assert_contains "a bare launch is routed" "dir=$HYDRA_HOME/profiles/w" "$(bash -c 'claude -p hi')"
  out=$(shim_install --shim)
  assert_contains "--shim again is a no-op" "already installed" "$out"
  assert_link "…shim still there" "$SB/lbin/claude" "$ROOT/claude-shim"
  assert_eq "…claude_bin unchanged" "$(real "$SB/real/claude")" "$(manifest | jq -r .claude_bin)"
  out=$(shim_install --unshim)
  assert_contains "--unshim reports the restore" "restored $SB/lbin/claude → $SB/real/claude" "$out"
  assert_link "the original link is back" "$SB/lbin/claude" "$SB/real/claude"
  assert_eq "the backup is gone" "" "$(ls "$SB/lbin/claude.hydra-bak" 2>/dev/null)"
  assert_eq "claude_bin is forgotten" "null" "$(manifest | jq -r .claude_bin)"
  assert_contains "a bare binary launch is unrouted again" "dir=<unset>" "$(bash -c 'claude -p hi')"
  assert_contains "the shell function still routes" "dir=$HYDRA_HOME/profiles/w" "$(bash -c "source '$ROOT/hydra.sh'; claude -p hi")"
  assert_ok "--unshim again is fine" shim_install --unshim
  assert_link "…and touches nothing" "$SB/lbin/claude" "$SB/real/claude"
fi

if test "shim: a real binary at ~/.local/bin/claude is moved aside, not deleted"; then
  mkdir -p "$SB/lbin"; mv "$SB/bin/claude" "$SB/lbin/claude"
  export PATH="$SB/lbin:$SB/bin:$ORIG_PATH"
  add w; set_usage w 0 0 0
  out=$(shim_install --shim)
  assert_contains "says it moved it" "moved the real binary $SB/lbin/claude to $SB/lbin/claude.hydra-bak" "$out"
  assert_eq "the binary survives" "1" "$(ls "$SB/lbin/claude.hydra-bak" | wc -l | tr -d ' ')"
  assert_eq "claude_bin points at the moved file" "$(real "$SB/lbin/claude.hydra-bak")" "$(manifest | jq -r .claude_bin)"
  assert_contains "routed" "dir=$HYDRA_HOME/profiles/w" "$(bash -c 'claude -p hi')"
  shim_install --unshim >/dev/null
  assert_eq "moved back" "1" "$(ls "$SB/lbin/claude" | wc -l | tr -d ' ')"
  assert_eq "no link left behind" "" "$(readlink "$SB/lbin/claude" 2>/dev/null)"
  assert_contains "runs directly again" "dir=<unset>" "$(bash -c 'claude -p hi')"
fi

if test "shim: install.sh --shim refuses when the real binary cannot be resolved"; then
  tools=$(tool_path)
  out=$(PATH="$tools" shim_install --shim); rc=$?
  assert_eq "no claude on PATH: exit 1" "1" "$rc"
  assert_contains "…and says so" "cannot find the real claude binary" "$out"
  assert_eq "…nothing linked" "" "$(ls "$SB/lbin/claude" 2>/dev/null)"
  mkdir -p "$SB/only"; ln -s "$ROOT/claude-shim" "$SB/only/claude"
  out=$(PATH="$SB/only:$tools" shim_install --shim); rc=$?
  assert_eq "the only claude is the shim itself: exit 1" "1" "$rc"
  assert_contains "…refused" "cannot find the real claude binary" "$out"
  ln -sf "$ROOT/hydra" "$SB/only/claude"
  out=$(PATH="$SB/only:$tools" shim_install --shim); rc=$?
  assert_eq "claude resolving to hydra itself: exit 1" "1" "$rc"
  assert_eq "…nothing linked" "" "$(ls "$SB/lbin/claude" 2>/dev/null)"
  assert_eq "…nothing recorded" "" "$(jq -r '.claude_bin // empty' "$HYDRA_HOME/profiles.json" 2>/dev/null)"
  out=$(HYDRA_CLAUDE_BIN="$ROOT/claude-shim" shim_install --shim); rc=$?
  assert_eq "HYDRA_CLAUDE_BIN at the shim is refused even with a real claude on PATH" "1" "$rc"
  mkdir -p "$SB/pinned"; cp "$SB/bin/claude" "$SB/pinned/claude"
  if HYDRA_CLAUDE_BIN="$SB/pinned/claude" shim_install --shim >/dev/null; then ok "HYDRA_CLAUDE_BIN names the binary to record"; else fail "HYDRA_CLAUDE_BIN names the binary to record" "install.sh failed"; fi
  assert_eq "…and it is the one recorded" "$(real "$SB/pinned/claude")" "$(manifest | jq -r .claude_bin)"
  assert_eq "hydra itself is still linked by the plain install" "1" "$(ls "$SB/lbin/hydra" | wc -l | tr -d ' ')"
fi

# ---------------------------------------------------------------- misc

if test "status table"; then
  add personal "" --existing; add w "" --no-login; set_usage personal 7 2 3
  out=$("$HYDRA" status --cached)
  assert_contains "header" "PROFILE" "$out"
  assert_contains "numbers" "7%    2%     3%" "$out"
  assert_contains "signed-out row" "not signed in on this machine" "$out"
  assert_contains "dash for missing numbers" "    -     -      -" "$out"
fi

# ---------------------------------------------------------------- status --json

if test "status: --json reports every window for every profile"; then
  add a; add b; set_usage a 12 12 22; set_usage b 1 0 0
  : >"$FAKE_LOG"
  "$HYDRA" status --json --cached >"$SB/status.json"
  assert_ok "parses" jq -e . "$SB/status.json"
  assert_eq "--cached makes no request" "0" "$(curl_calls)"
  assert_eq "one entry per profile, in profile_names order" "a b" "$(jq -r '[.profiles[].name] | join(" ")' "$SB/status.json")"
  assert_eq "a's three windows" "[12,12,22]" "$(jq -c '.profiles[0] | [.session.pct, .weekly.pct, .fable.pct]' "$SB/status.json")"
  assert_eq "b's three windows" "[1,0,0]" "$(jq -c '.profiles[1] | [.session.pct, .weekly.pct, .fable.pct]' "$SB/status.json")"
  assert_eq "threshold from the manifest" "90" "$(jq .threshold "$SB/status.json")"
  assert_eq "now is hydra's clock" "$NOW" "$(jq .now "$SB/status.json")"
  assert_eq "dir is the expanded path" "$HYDRA_HOME/profiles/a" "$(jq -r '.profiles[0].dir' "$SB/status.json")"
  assert_eq "email" "a@example.com" "$(jq -r '.profiles[0].email' "$SB/status.json")"
  assert_eq "signed_in / disabled / locked" "true false false" "$(jq -r '.profiles[0] | "\(.signed_in) \(.disabled) \(.locked)"' "$SB/status.json")"
  assert_eq "fetched_at / source / auth" "$NOW api ok" "$(jq -r '.profiles[0] | "\(.fetched_at) \(.source) \(.auth)"' "$SB/status.json")"
  assert_eq "resets are epoch seconds" "4070908800" "$(jq '.profiles[0].session.resets' "$SB/status.json")"
  assert_eq "severity is passed through" "normal" "$(jq -r '.profiles[0].weekly.severity' "$SB/status.json")"
  assert_eq "state" "ok" "$(jq -r '.profiles[0].state' "$SB/status.json")"
  jq '.threshold = 20' "$HYDRA_HOME/profiles.json" >"$SB/m" && mv "$SB/m" "$HYDRA_HOME/profiles.json"
  assert_eq "a custom threshold is reported" "20" "$(statusj .threshold --cached)"
  assert_eq "nothing secret: no token anywhere in the document" "0" "$(grep -c 'tok-' "$SB/status.json" | tr -d ' ')"
fi

if test "status: --json state agrees with the table, row for row"; then
  add a; add b; add c "" --no-login; add d; add e; add f; add g
  set_usage a 5 92 5                                    # over the threshold
  set_usage b 1 0 0; "$HYDRA" disable b >/dev/null 2>&1 # disabled
  rm -f "$HYDRA_HOME/cache/d.json"                      # signed in, never fetched
  LOCKED='"some_reason"' set_usage e 0 0 0              # locked
  set_usage f 0 0 0; FAKE_CURL_CODE=401 "$HYDRA" refresh --force f >/dev/null   # token lapsed
  set_usage g 1 2 3                                     # fine
  json=$("$HYDRA" status --json --cached); table=$("$HYDRA" status --cached)
  same_state() { # <name> <expected state>: the JSON says so, and so does the table row
    assert_eq "json: $1 is '$2'" "$2" "$(printf '%s' "$json" | jq -r --arg n "$1" '.profiles[] | select(.name == $n) | .state')"
    assert_contains "table: $1 row agrees" "$2" "$(printf '%s' "$table" | grep "^$1 ")"
  }
  same_state a exhausted
  same_state b disabled
  same_state c "not signed in on this machine"
  same_state d "no usage data yet"
  same_state e locked
  same_state f "token stale — refreshes on next launch"
  same_state g ok
  assert_eq "every state is one of the documented strings" "" "$(printf '%s' "$json" | jq -r '.profiles[].state
    | select(. as $s | ["not signed in on this machine","disabled","locked","exhausted","token stale — refreshes on next launch","no usage data yet","ok"] | index($s) == null)')"
  assert_eq "missing windows are null, not errors" "null null null" "$(printf '%s' "$json" | jq -r '.profiles[] | select(.name == "d") | "\(.session) \(.weekly) \(.fable)"')"
fi

if test "status: --json puts nothing but the document on stdout"; then
  assert_fails "no profiles: dies like the table does" "$HYDRA" status --json --cached
  add a; set_usage a 1 2 3
  out=$("$HYDRA" status --json --cached 2>/dev/null)
  assert_eq "exactly one JSON document" "1" "$(printf '%s\n' "$out" | jq -c . 2>/dev/null | wc -l | tr -d ' ')"
  assert_not_contains "no table header" "PROFILE" "$out"
  out=$(HYDRA_NOW=$((NOW + 200)) "$HYDRA" status --json 2>/dev/null)   # stale → the refresh runs, silently
  assert_eq "a refresh leaves stdout clean too" "1" "$(printf '%s\n' "$out" | jq -c . 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "…and the refresh happened" "$((NOW + 200))" "$(printf '%s' "$out" | jq '.profiles[0].fetched_at')"
fi

if test "status: --json --force refreshes first and reports the new numbers"; then
  add a; set_usage a 1 1 1
  usage 44 55 66 >"$FAKE_CURL_BODY"; : >"$FAKE_LOG"
  assert_eq "--cached: the old numbers, no request" "[1,1,1]" "$(statusj '.profiles[0] | [.session.pct, .weekly.pct, .fable.pct] | tostring' --cached)"
  assert_eq "no request made" "0" "$(curl_calls)"
  assert_eq "fresh data is not refetched without --force" "[1,1,1]" "$(statusj '.profiles[0] | [.session.pct, .weekly.pct, .fable.pct] | tostring')"
  assert_eq "still no request" "0" "$(curl_calls)"
  assert_eq "--force: the refreshed numbers" "[44,55,66]" "$(statusj '.profiles[0] | [.session.pct, .weekly.pct, .fable.pct] | tostring' --force)"
  assert_eq "one request" "1" "$(curl_calls)"
fi

if test "HYDRA_MANIFEST relocates the manifest"; then
  export HYDRA_MANIFEST="$SB/dotfiles/hydra.json"
  add w "" --no-login
  assert_eq "written to the custom path" "~/.hydra/profiles/w" "$(jq -r .profiles.w.dir "$HYDRA_MANIFEST")"
  assert_eq "nothing at the default path" "" "$(ls "$HYDRA_HOME/profiles.json" 2>/dev/null)"
fi

if test "login re-authenticates an existing profile"; then
  add w "" --no-login
  FAKE_EMAIL=new@example.com "$HYDRA" login w >/dev/null 2>&1
  assert_eq "email updated" "new@example.com" "$(manifest | jq -r .profiles.w.email)"
  assert_eq "usage fetched after login" "1" "$(grep -c '^curl' "$FAKE_LOG")"
fi

printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
