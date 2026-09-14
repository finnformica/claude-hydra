#!/usr/bin/env bash
# Links `hydra` onto your PATH and sources hydra.sh from your shell rc.
#
#   install.sh           the shell function only: `claude` in your shell is routed
#   install.sh --shim    also install hydra's `claude` shim in $HYDRA_HOME/bin, ahead of
#                        the real binary on PATH, so every launcher is routed — editors,
#                        scripts, `claude -p`. Survives Claude Code's own updater.
#   install.sh --unshim  remove the shim again
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin="${HYDRA_BIN_DIR:-$HOME/.local/bin}"
rc="${HYDRA_RC:-${ZDOTDIR:-$HOME}/.zshrc}"
shim="$here/claude-shim"
hydra="$here/hydra"
hydra_home="${HYDRA_HOME:-$HOME/.hydra}"
shimdir="$hydra_home/bin"
shimlink="$shimdir/claude"

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

# The rc line that puts the shim ahead of the real binary for every shell.
# hydra.sh does the same when the directory exists, but a launcher that reads
# the rc without sourcing hydra.sh still needs it. Written with $HOME so the rc
# stays portable; the trailing marker is what --unshim removes.
path_line() {
  case "$shimdir" in "$HOME/"*) printf 'export PATH="$HOME%s:$PATH" # hydra-shim' "${shimdir#"$HOME"}" ;;
                     *) printf 'export PATH="%s:$PATH" # hydra-shim' "$shimdir" ;; esac
}

# Before the shim moved to $HYDRA_HOME/bin it *replaced* $bin/claude, keeping
# the original as claude.hydra-bak and pinning claude_bin. Claude Code's updater
# rewrote that link, which silently unrouted every direct launch. Put $bin/claude
# back the way the updater (or the user) left it and drop the pin — the shadow
# shim takes over and resolves the binary on every launch.
restore_old_layout() {
  local target="$bin/claude" bak="$bin/claude.hydra-bak" old=0
  if exists "$target" && is_shim "$target"; then
    rm "$target"; old=1
    if exists "$bak"; then
      mv "$bak" "$target"
      if [ -L "$target" ]; then echo "old layout: restored $target → $(readlink "$target") from $bak"
      else echo "old layout: restored $target from $bak"; fi
    else
      echo "old layout: removed the shim at $target (there was no claude there before it)"
    fi
  elif exists "$bak"; then
    old=1
    if exists "$target"; then
      # The updater has already put a real claude back; the backup is stale.
      if [ -L "$bak" ]; then rm "$bak"; echo "old layout: removed the stale backup $bak ($target is already the real claude)"
      else echo "old layout: $bak is an old copy of the binary and $target is already the real claude — delete the backup when you like"; fi
    else
      mv "$bak" "$target"; echo "old layout: restored $target from $bak"
    fi
  fi
  [ "$old" -eq 1 ] && "$hydra" bin --unset 2>&1 | sed 's/^/old layout: /'
  return 0
}

install_shim() {
  restore_old_layout

  # hydra walks PATH for the real binary (skipping its own shim) exactly as it
  # will on every launch; refuse rather than install a shim with nothing behind it.
  local real
  real=$("$hydra" bin 2>/dev/null) || real=""
  if [ -z "$real" ]; then
    echo "install.sh: cannot find the real claude binary, so the shim is NOT installed — is Claude Code installed and on PATH?" >&2
    exit 1
  fi

  mkdir -p "$shimdir"
  if exists "$shimlink"; then
    if ! is_shim "$shimlink"; then
      echo "install.sh: $shimlink exists and is not hydra's shim; move it aside first" >&2
      exit 1
    fi
    if [ "$(readlink "$shimlink" 2>/dev/null || true)" = "$shim" ]; then echo "shim already installed at $shimlink"
    else rm "$shimlink"; ln -s "$shim" "$shimlink"; echo "relinked $shimlink → $shim"; fi
  else
    ln -s "$shim" "$shimlink"; echo "linked $shimlink → $shim"
  fi
  echo "the real claude is $real (found on PATH at every launch; hydra bin)"

  line=$(path_line)
  if grep -qsF '# hydra-shim' "$rc"; then echo "$rc already puts $shimdir on PATH"
  else printf '%s\n' "$line" >>"$rc"; echo "added to $rc: $line"; fi

  first=$(command -v claude 2>/dev/null || true)
  if [ -z "$first" ] || ! [ "$first" -ef "$shimlink" ]; then
    echo "note: in this shell $shimdir is not ahead of ${first:-(no claude)} on PATH — exec \$SHELL, and add it to"
    echo "      the PATH of any launcher that does not read your shell rc; hydra doctor checks this"
  fi
}

uninstall_shim() {
  local did=0
  if exists "$shimlink" && is_shim "$shimlink"; then
    rm "$shimlink"; rmdir "$shimdir" 2>/dev/null || true
    echo "removed the shim at $shimlink"; did=1
  fi
  if grep -qsF '# hydra-shim' "$rc"; then
    grep -vF '# hydra-shim' "$rc" >"$rc.hydra.$$" || true
    mv "$rc.hydra.$$" "$rc"
    echo "removed the PATH line from $rc"; did=1
  fi
  if exists "$bin/claude.hydra-bak" || { exists "$bin/claude" && is_shim "$bin/claude"; }; then
    restore_old_layout; did=1
  fi
  [ "$did" -eq 1 ] || echo "no hydra shim installed"
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
if [ "$mode" = shim ]; then echo "  hydra doctor                     # confirm the shim is first on PATH"
else echo "  $0 --shim                        # optional: route claude -p from scripts and editors too"; fi
