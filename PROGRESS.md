
## 2026-11-22 — ing.sh busybox fixes, lolf.art deploy, secrets scanning

- **Outcome:** `ing.sh` shims `install(1)` for get.chezmoi.io on busybox (OpenWrt/slim Alpine), and removes the chezmoi binary after the final apply when `$HOME` has <1GB free. `make` publishes changed `ing.sh`/`abc.sh` to lolf.art (copy, commit, push). gitleaks pre-commit hook (`.githooks/`, enable with `make hooks`), `.gitleaks.toml` allowlists for 2 false positives (`.idea/` IDE state; claude-tail help text in fe9f55a), `AGENTS.md` (public repo rules), `.skills/secrets-scan/SKILL.md`.
- **Also:** `Makefile`, `AGENTS.md`, `PROGRESS.md` added to `.chezmoiignore`. Without that, chezmoi would deploy them into `$HOME`.
- **Verification:** Alpine container with `install` removed: chezmoi installed via the shim, cleanup removed it. `gitleaks git`/`gitleaks dir` both clean. Hook blocked a staged fake `ghp_` token (exit 1). It did NOT catch an AWS `...EXAMPLE...` key, which gitleaks allowlists by default.
- **Not run:** full ing.sh end-to-end on a real router.

## 2026-11-22 (cont.) — OpenWrt clone path, deploy pipeline

- **Outcome:** `ing.sh` on OpenWrt 25.12 (dropbear, apk, 22MB overlay) chooses how to clone. If the forwarded agent works with GitHub, it clones over ssh (`ssh -y`, `GIT_SSH_VARIANT=simple`). Otherwise it uses https, and if git has no `git-remote-https` it sets chezmoi `useBuiltinGit: true` instead of installing git-http. Also: chezmoi is moved into a dir on PATH, `id -un` replaces `whoami`, and PATH dedupe (`typeset -U` in zshrc).
- **`make`:** stamps `# modified:` on published scripts and pushes lolf.art. It then checks the live stamps and runs `wrangler deploy` if any script is stale. It's idempotent. AGENTS.md requires running it before ending a session.
- **Verification:** Alpine container with no https helper: plain git fails, builtin-git init+update OK. On vantr3k, `ssh -T git@github.com` and `git ls-remote` over the forwarded agent both work. `make` → `live ✓`.
- **Not run:** the ssh clone branch of ing.sh end to end on the router.
