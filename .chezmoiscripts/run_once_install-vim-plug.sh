#!/bin/sh
# Install vim-plug and plugins if not already present
PLUG="$HOME/.vim/autoload/plug.vim"
if [ ! -f "$PLUG" ]; then
  curl -fLo "$PLUG" --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
fi

# Install plugins headlessly
vim -es -u "$HOME/.vimrc" -c "PlugInstall" -c "qa" 2>/dev/null || true
