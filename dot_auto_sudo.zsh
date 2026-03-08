# ---- auto sudo aliases (zsh-safe) ----
SUDO_BIN=/usr/bin/sudo

if [[ -r "$HOME/.auto_sudo" ]]; then
  while IFS= read -r cmd || [[ -n "$cmd" ]]; do
    # strip CR (Windows line endings), trim whitespace
    cmd=${cmd//$'\r'/}
    cmd=${cmd##[[:space:]]#}
    cmd=${cmd%%[[:space:]]#}

    # skip blank lines and comments
    [[ -z "$cmd" || "$cmd" == \#* ]] && continue

    # define alias using zsh's "alias name=value" string form
    alias -- "${cmd}=${SUDO_BIN} ${cmd}"
  done < "$HOME/.auto_sudo"
fi
