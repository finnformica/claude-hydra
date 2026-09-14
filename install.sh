#!/usr/bin/env bash
# Links `hydra` onto your PATH and sources hydra.sh from your shell rc.
#
#   install.sh           the shell function only: `claude` in your shell is routed
#   install.sh --shim    also put hydra's shim in place of the `claude` on PATH, so
#                        every launcher is routed — editors, scripts, `claude -p`
#   install.sh --unshim  put the original `claude` back
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin="${HYDRA_BIN_DIR:-$HOME/.local/bin}"
rc="${HYDRA_RC:-${ZDOTDIR:-$HOME}/.zshrc}"
shim="$here/claude-shim"
hydra="$here/hydra"

mode=install
case "${1:-}" in
  "") ;;
  --shim) mode=shim ;;
  --unshim) mode=unshim ;;
  *) echo "usage: install.sh [--shim | --unshim]" >&2; exit 2 ;;
esac

# Same test hydra uses: the shim announces itself in its header, and hydra
# itself must never be mistaken for the real binary either.
is_shim() { [ "$1" -ef "$hydra" ] || { head -c 512 "$1" 2>/dev/null || true; } | grep -q 'hydra-shim'; }
exists()  { [ -e "$1" ] || [ -L "$1" ]; }   # a dangling symlink still occupies the name

install_hydra() {
  for dep in jq curl; do
    command -v "$dep" >/dev/null 2>&1 || { echo "install.sh: $dep is required (brew install $dep)" >&2; exit 1; }
  done

  mkdir -p "$bin"
  chmod +x "$hydra" "$shim"
  ln -sf "$hydra" "$bin/hydra"
  echo "linked $bin/hydra → $hydra"

  case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "note: $bin is not on your PATH — add it before the source line below" ;;
  esac

  line="source \"$here/hydra.sh\""
  if ! grep -qsF "$line" "$rc"; then
    printf '\n# hydra: route claude through the profile with the most headroom\n%s\n' "$line" >>"$rc"
    echo "added to $rc: $line"
  else
    echo "$rc already sources hydra.sh"
  fi
}

# The real binary must be pinned down *before* the shim takes its place on
# PATH: once $bin/claude is the shim, `command -v claude` finds hydra itself.
install_shim() {
  local target="$bin/claude" candidate="" real="" moved=0 already=0

  if [ -n "${HYDRA_CLAUDE_BIN:-}" ]; then candidate="$HYDRA_CLAUDE_BIN"   # the user's explicit pick
  elif exists "$target" && ! is_shim "$target"; then candidate="$target"
  elif candidate=$(command -v claude 2>/dev/null) && ! is_shim "$candidate"; then :
  else candidate=""; fi

  # hydra validates the candidate (or walks PATH itself) and prints the resolved
  # path; it refuses its own shim, and fails when there is no real claude at all.
  if [ -n "$candidate" ]; then real=$(HYDRA_CLAUDE_BIN="$candidate" "$hydra" bin) || real=""
  else real=$("$hydra" bin) || real=""; fi
  if [ -z "$real" ]; then
    echo "install.sh: cannot find the real claude binary, so the shim is NOT installed — is Claude Code installed and on PATH?" >&2
    exit 1
  fi

  if exists "$target" && is_shim "$target"; then
    already=1
  elif exists "$target"; then
    # Keep whatever was there (on native installs a symlink to the versioned
    # binary) so --unshim can put back exactly what it found.
    mv "$target" "$target.hydra-bak"; moved=1
    if [ -L "$target.hydra-bak" ]; then echo "replaced $target → $(readlink "$target.hydra-bak") (kept as $target.hydra-bak)"
    else real="$target.hydra-bak"; echo "moved the real binary $target to $target.hydra-bak"; fi
  fi

  if ! "$hydra" bin "$real" 2>/dev/null; then
    [ "$moved" -eq 1 ] && mv "$target.hydra-bak" "$target"
    echo "install.sh: could not record $real as the real binary; nothing changed" >&2
    exit 1
  fi
  if [ "$already" -eq 1 ]; then echo "shim already installed at $target"
  else ln -s "$shim" "$target"; echo "linked $target → $shim"; fi
  echo "the real claude is $real (hydra bin)"

  first=$(command -v claude 2>/dev/null || true)
  if [ -n "$first" ] && ! is_shim "$first"; then
    echo "note: $first comes before $bin on PATH, so the shim is not the claude your shell runs"
  fi
}

uninstall_shim() {
  local target="$bin/claude"
  if exists "$target" && is_shim "$target"; then
    rm "$target"
    if exists "$target.hydra-bak"; then
      mv "$target.hydra-bak" "$target"
      if [ -L "$target" ]; then echo "restored $target → $(readlink "$target")"; else echo "restored $target"; fi
    else
      echo "removed the shim at $target (there was no claude there before it)"
    fi
  else
    echo "no hydra shim at $target"
  fi
  "$hydra" bin --unset 2>/dev/null || true
}

case "$mode" in
  unshim) uninstall_shim; exit 0 ;;
  install) install_hydra ;;
  shim) install_hydra; echo; install_shim ;;
esac

echo
echo "Next:"
echo "  exec \$SHELL                      # reload"
echo "  hydra add personal --existing    # register the account already signed in to ~/.claude"
echo "  hydra add work                   # sign a second account in"
echo "  hydra status"
[ "$mode" = shim ] || echo "  $0 --shim                        # optional: route claude -p from scripts and editors too"
