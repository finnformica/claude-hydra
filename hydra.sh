# hydra — route `claude` through the profile with the most headroom.
# Source this from ~/.zshrc or ~/.bashrc (install.sh does it for you).
#
#   claude [args…]           → freshest profile
#   claude <profile> [args…] → that profile
#   claude mcp|auth|update…  → untouched

# The opt-in shim (install.sh --shim) lives in $HYDRA_HOME/bin, shadowing the
# real binary rather than replacing it. Put that directory first on PATH so a
# bare `claude` from anything this shell starts is routed too — and stays
# routed after Claude Code's updater rewrites ~/.local/bin/claude.
_hydra_bin="${HYDRA_HOME:-$HOME/.hydra}/bin"
if [ -d "$_hydra_bin" ]; then
  case ":$PATH:" in ":$_hydra_bin:"*) ;; *) PATH="$_hydra_bin:$PATH" ;; esac
fi
unset _hydra_bin

# Tells `hydra doctor` and `hydra status` that this shell (or an ancestor) has
# run this file. A terminal opened before install.sh appended its lines to the
# rc has neither the claude() function nor $HYDRA_HOME/bin on PATH, and the
# only symptom is that `claude` quietly runs the real binary; the marker lets
# doctor say "reload the shell" instead of just describing the PATH.
export HYDRA_SOURCED=1

# Claude Code's own installers have written `alias claude=…` to the rc in the
# past. In zsh an alias beats a function of the same name, and an alias in
# scope while this function is being *defined* would even rename it.
unalias claude 2>/dev/null

claude() {
  if command -v hydra >/dev/null 2>&1; then
    hydra exec "$@"
  else
    command claude "$@"
  fi
}

# --- tab completion: profile names for `hydra …` and for `claude <profile>` ---

if [ -n "${ZSH_VERSION:-}" ]; then
  _hydra_profiles() {
    local -a profiles
    profiles=(${(f)"$(hydra names 2>/dev/null)"})
    _describe -t profiles 'profile' profiles
  }
  _hydra() {
    local -a cmds
    cmds=(
      'add:new profile' 'login:sign in / re-authenticate' 'remove:delete a profile'
      'rename:relabel a profile' 'enable:put a profile back in the rotation' 'disable:take a profile out of the rotation' 'list:profiles and config dirs' 'status:usage per profile'
      'refresh:fetch usage now' 'pick:which profile a bare claude would use'
      'link:reapply shared-config symlinks' 'dir:print a config dir' 'exec:launch claude on a profile'
      'bin:the real claude binary hydra execs'
      'doctor:check the shim and the real binary'
      'help:show help'
    )
    if (( CURRENT == 2 )); then
      _describe -t commands 'command' cmds
      _hydra_profiles
    else
      case "${words[2]}" in
        login|remove|rm|rename|enable|disable|dir|has|refresh|link|exec) _hydra_profiles ;;
        add) [[ "${words[CURRENT]}" == -* ]] && compadd -- --existing --dir --no-login ;;
        status) compadd -- --cached --force --json ;;
        bin) compadd -- --unset; _files ;;
        *) _files ;;
      esac
    fi
  }
  _hydra_claude() {
    if (( CURRENT == 2 )); then
      _hydra_profiles
      _files
    else
      _files
    fi
  }
  if (( $+functions[compdef] )); then
    compdef _hydra hydra
    compdef _hydra_claude claude
  fi
elif [ -n "${BASH_VERSION:-}" ]; then
  _hydra_bash() {
    local cur="${COMP_WORDS[COMP_CWORD]}" cmd="${COMP_WORDS[1]:-}"
    local cmds="add login remove rename enable disable list status refresh pick link dir exec bin doctor help"
    if [ "$COMP_CWORD" -eq 1 ]; then
      COMPREPLY=($(compgen -W "$cmds $(hydra names 2>/dev/null)" -- "$cur"))
    else
      case "$cmd" in
        login|remove|rm|rename|enable|disable|dir|has|refresh|link|exec)
          COMPREPLY=($(compgen -W "$(hydra names 2>/dev/null)" -- "$cur")) ;;
        status) COMPREPLY=($(compgen -W "--cached --force --json" -- "$cur")) ;;
        *) COMPREPLY=($(compgen -f -- "$cur")) ;;
      esac
    fi
  }
  _hydra_claude_bash() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if [ "$COMP_CWORD" -eq 1 ]; then
      COMPREPLY=($(compgen -W "$(hydra names 2>/dev/null)" -- "$cur") $(compgen -f -- "$cur"))
    else
      COMPREPLY=($(compgen -f -- "$cur"))
    fi
  }
  complete -F _hydra_bash hydra
  complete -F _hydra_claude_bash claude
fi
