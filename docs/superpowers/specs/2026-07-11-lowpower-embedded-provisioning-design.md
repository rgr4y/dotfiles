# Low-power / embedded auto-provisioning — design

Date: 2026-07-11

## Goal
Auto-detect low-power / space-constrained systems and install the lightest
comfortable userland. Comfy but minimal. Space is the hard constraint.

## Decisions (locked)

### Tiers — exactly 3
`full`, `lite`, `bare`. Rename `tiny` -> `bare` everywhere: `.chezmoidata.yaml`,
`.chezmoiignore`, every `.tmpl` conditional, `install.sh` wizard, `install.linux.sh`.

### lowpower detection (install.sh bootstrap)
```
lowpower = arch in {armv6l,armv7l,armhf} OR pkgmgr in {opkg,apk} OR free_disk_MB < 128
```
- aarch64 alone is NOT lowpower (Graviton/Pi4/arm64 VM); needs opkg/apk or <128MB.
- When lowpower: hard-override effective profile -> `bare`; write `profile: bare`
  and `lowpower: true` into `.chezmoidata.yaml`. Templates key on `.profile == "bare"`.

### Wizard menu fix
All `read -rsn1` reads in `select_profile`/`select_modules`/`_select_chezmoi_dir`
read from `/dev/tty`; if no tty, skip menu and use detected default. Root cause of
"never see the menu": `curl|bash` makes stdin the pipe (EOF), so reads return
instantly and the wizard auto-picks the default.

### apk & opkg — space-checked incremental install
Ordered: `zsh -> vim(-tiny) -> bash -> curl -> nc (check first, skip if absent) -> htop`.
Re-check free space before each package; stop and log skips if under floor
(opkg 2MB, apk configurable). No silent truncation.

### vim-tiny `syntax on`
- `dot_vimrc.tmpl`: omit `syntax on` when effective bare; keep `silent! syntax on`
  fallback so it never errors.
- Installer smoke-test after apk/opkg vim install: `vim -es +q`; on error strip
  `syntax on` from applied vimrc.

### zsh plugins on bare — manual source, no zi
Direct `git clone` + manual source of zsh-autosuggestions AND zsh-syntax-highlighting.
No zi manager on bare.

### Prompt strips (bare)
- Remove git segment entirely.
- hostname shim: `hostname -s || uname -n || $HOST`.

### tmux — physical machine only
Install `.tmux.conf` + `.tmux/**` only when `profile == full` AND not an SSH session
(SSH_CONNECTION/SSH_TTY/SSH_CLIENT empty).

### dot_local/bin copy matrix
| script         | full | lite | bare |
|----------------|------|------|------|
| dysk           | yes  | no   | no   |
| delint         | yes  | yes  | no   |
| claude-tail    | yes  | yes  | no   |
| diff-so-fancy  | yes  | yes  | no   |
| lsusb          | yes  | yes  | only if lsusb && perl (Linux); mac always |

### bash -> zsh (not an alias)
Guarded `exec zsh` in `~/.bashrc` (+ `~/.profile`): skip if non-interactive, if
`$ZSH_VERSION` set, or if no zsh. Idempotent marker. Keeps `#!/bin/bash` scripts intact.

### chezmoi disk + self-cleanup
- free<128MB OR lowpower: stage chezmoi in `/tmp/.local/bin`, init+apply, then remove
  the chezmoi binary; strip `.git` dirs (chezmoi source repo, `~/.zsh/*` clones, `~/.zi`).
- else: existing interactive selector (threshold messaging bumped to 128MB).
