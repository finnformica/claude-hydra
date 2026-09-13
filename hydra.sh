# hydra — route `claude` through the profile with the most headroom.
# Source this from ~/.zshrc or ~/.bashrc (install.sh does it for you).
#
#   claude [args…]         → freshest profile
#   claude <profile> [args…] → that profile
#   claude mcp|auth|update… → untouched
claude() {
  if command -v hydra >/dev/null 2>&1; then
    hydra exec "$@"
  else
    command claude "$@"
  fi
}
