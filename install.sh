#!/usr/bin/env bash
# Links `hydra` onto your PATH and sources hydra.sh from your shell rc.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin="${HYDRA_BIN_DIR:-$HOME/.local/bin}"
rc="${HYDRA_RC:-${ZDOTDIR:-$HOME}/.zshrc}"

for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "install.sh: $dep is required (brew install $dep)" >&2; exit 1; }
done

mkdir -p "$bin"
chmod +x "$here/hydra"
ln -sf "$here/hydra" "$bin/hydra"
echo "linked $bin/hydra → $here/hydra"

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

echo
echo "Next:"
echo "  exec \$SHELL                      # reload"
echo "  hydra add personal --existing    # register the account already signed in to ~/.claude"
echo "  hydra add work                   # sign a second account in"
echo "  hydra status"
