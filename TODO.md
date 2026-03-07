# Dotfiles 2026 — What's Next

## Working Now
- [x] chezmoi templates with bare/full profiles
- [x] install.sh wizard (spacebar multi-select)
- [x] zi replaces OMZ (agnoster via snippets)
- [x] Vim bare (5 plugins, no CoC) vs full (everything)
- [x] SSH config templated (OS + profile conditionals)
- [x] Package installer (apt/brew/yum auto-detect)
- [x] diff-so-fancy standalone install
- [x] .aliases symlink for bash compat
- [x] EXTENDED_HISTORY + explicit HISTFILE
- [x] Tested on fresh Linux container (claude-ssh)
- [x] Pushed to rgr4y/dotfiles branch `2026`

## Still TODO

### Before daily-driving
- [ ] Point `lolf.art/ing.sh` to raw install.sh from GitHub (or proxy it)
- [ ] Test install.sh end-to-end from curl on a truly fresh box (not just scp)
- [ ] Run `chezmoi apply --dry-run` on mimi (macOS/full) to verify darwin paths
- [ ] Add more scripts to `bin/` (whatever you want to bring along)
- [ ] Remove tmux plugin .git dirs from repo (gitignore is set but they got committed)

### Polish
- [ ] install.sh: chezmoi init needs `--branch 2026` until you make it default
- [ ] install.sh: vim +PlugInstall should run automatically after apply
- [ ] goodshit alias uses pbcopy — needs OS guard for Linux (xclip/xsel)
- [ ] SSH config: codespace proxy entry has hardcoded /opt/homebrew path
- [ ] .chezmoiignore needs `.tmpl` extension to use template conditionals (rename it)
- [ ] tmux.conf references ~/.tmux-powerline — may not exist on bare installs
- [ ] tmux.conf copy-mode uses pbcopy — needs OS conditional

### When ready to replace main
1. Set `2026` as default branch in GitHub settings
2. Archive or delete old `main` branch
3. Update `chezmoi init` commands everywhere to drop `--branch`
4. Update lolf.art redirect if it was pointing at main

## Backups
- `~/workspace/chezmoi-backup-20260222` — original chezmoi source
- `~/workspace/dotfiles-backup-20260222` — duplicate safety copy
