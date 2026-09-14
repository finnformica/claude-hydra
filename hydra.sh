# hydra — route `claude` through the profile with the most headroom.
# Source this from ~/.zshrc or ~/.bashrc (install.sh does it for you).
#
#   claude [args…]           → freshest profile
#   claude <profile> [args…] → that profile
#   claude mcp|auth|update…  → untouched
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
    local cmds="add login remove rename enable disable list status refresh pick link dir exec help"
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
