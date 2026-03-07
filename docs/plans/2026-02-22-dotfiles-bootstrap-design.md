# Dotfiles Bootstrap — Design & Plan

## What We're Building

A single `install.sh` that turns any fresh box into your environment.
Bare by default (servers), full optional (workstations).

## Bootstrap Flow

```
curl -sL <url>/install.sh | bash
  → detect OS (darwin/linux)
  → detect sudo
  → install chezmoi → ~/.local/bin
  → install zi (replaces OMZ entirely)
  → install vim-plug
  → interactive wizard:
      1. bare / full (single select)
      2. spacebar checklist: nvm, pyenv, bun, php, copilot, tmux, fzf, vscode
  → write ~/.local/share/chezmoi/.chezmoidata.yaml
  → chezmoi init --apply <repo>
```

## File Changes

### DELETE (replaced by templates)
- `dot_zshrc` → `dot_zshrc.tmpl`
- `dot_zshrc.common.zsh` → merged into dot_zshrc.tmpl
- `dot_zshrc.copilot.zsh` → conditional block in dot_zshrc.tmpl
- `dot_zshrc.nvm.zsh` → conditional block in dot_zshrc.tmpl
- `dot_zshrc.bun.zsh` → conditional block in dot_zshrc.tmpl
- `dot_zshrc.vscode.zsh` → conditional block in dot_zshrc.tmpl
- `dot_zshrc.aliases.zsh` → `dot_zshrc.aliases.tmpl` (also symlinked to ~/.aliases)
- `dot_vimrc` → `dot_vimrc.tmpl`
- `private_dot_ssh/private_config` → `private_dot_ssh/private_config.tmpl`
- `readonly_dot_zshrc.zwc` → DELETE (compiled cache, regenerates)

### NEW
- `install.sh` — standalone bootstrap (lives in repo root, NOT deployed by chezmoi)
- `.chezmoidata.yaml` — wizard output template
- `.chezmoiignore.tmpl` — conditional ignores based on profile/modules

### UNCHANGED
- `dot_tmux.conf`, `dot_tmux/` — deployed only if tmux module selected
- `dot_gitconfig`, `dot_gitignore_global` — always deployed
- `dot_yamllint` — always deployed
- `bin/executable_ports` — always deployed
- `dot_vim/autoload/plug.vim` — always deployed
- `dot_vim/colors/darcula.vim` — always deployed

## .zshrc.tmpl Structure

```
1. PATH ($HOME/bin, $HOME/.local/bin)
2. History block (HISTFILE=$HOME/.zsh_history, sizes, setopts incl EXTENDED_HISTORY)
3. OS detection (is_macos, is_linux, is_wsl) — from {{ .chezmoi.os }}
4. zi bootstrap + core plugins (autosuggestions, syntax-highlighting, z)
5. {{ if .modules.nvm }} nvm lazy-load block {{ end }}
6. {{ if .modules.pyenv }} pyenv block {{ end }}
7. {{ if .modules.bun }} bun block {{ end }}
8. {{ if .modules.copilot }} copilot functions {{ end }}
9. {{ if .modules.fzf }} fzf keybindings {{ end }}
10. {{ if .modules.vscode }} vscode terminal detection + early return {{ end }}
11. Prompt (custom prompt, git segment, command duration — always)
12. source ~/.zshrc.aliases.zsh
13. Completions
```

No OMZ anywhere. zi handles everything.

## Aliases File

- POSIX-safe aliases at top (git, navigation) — work in bash
- ZSH functions guarded: `if [ -n "$ZSH_VERSION" ]; then`
- Includes: fastsync, psgrep, short_pwd, phpd, yarnd, goodshit
- OS-conditional: darwin gets pbcopy/wireshark, linux gets python→python3
- Symlinked to ~/.aliases

## Vim Bare vs Full

**Bare** (~5 plugins, no node):
- polyglot, surround, commentary, ale, darcula
- All keybindings, mouse, search, tabs preserved
- No CoC, no airline, no nerdtree, no fzf.vim

**Full** (current setup, fixed):
- Everything current + fix stray Plug after plug#end()
- CoC + all extensions
- Airline, nerdtree, fzf.vim, fugitive, etc.

## SSH Config Template

- github.com + bitbucket.org blocks: always
- UseKeychain: darwin only
- Personal hosts (nd-*, pi, slackbox, etc.): full profile only
- Hardcoded /Users/rob paths: replaced with $HOME via template

## .chezmoidata.yaml Example

```yaml
profile: bare
modules:
  nvm: false
  pyenv: false
  bun: false
  php: false
  copilot: false
  tmux: false
  fzf: true
  vscode: false
```

## Implementation Steps

1. Create `install.sh` with wizard (spacebar multi-select UI)
2. Create `.chezmoidata.yaml` defaults + `.chezmoiignore.tmpl`
3. Convert `dot_zshrc` → `dot_zshrc.tmpl` (merge all .zshrc.* files into one)
4. Convert `dot_zshrc.aliases.zsh` → `dot_zshrc.aliases.tmpl` + ~/.aliases symlink
5. Convert `dot_vimrc` → `dot_vimrc.tmpl` (bare/full conditional)
6. Convert SSH config → template with OS + profile conditionals
7. Test bare profile on docker container (ssh localhost -p 2222)
8. Test full profile locally (chezmoi apply --dry-run)
9. Delete old non-template files, commit
