
## 2026-11-22 — ing.sh busybox fixes, lolf.art deploy, secrets scanning

- **Outcome:** `ing.sh` shims `install(1)` for get.chezmoi.io on busybox (OpenWrt/slim Alpine), and removes the chezmoi binary after the final apply when `$HOME` has <1GB free. `make` publishes changed `ing.sh`/`abc.sh` to lolf.art (copy, commit, push). gitleaks pre-commit hook (`.githooks/`, enable with `make hooks`), `.gitleaks.toml` allowlists for 2 false positives (`.idea/` IDE state; claude-tail help text in fe9f55a), `AGENTS.md` (public repo rules), `.skills/secrets-scan/SKILL.md`.
- **Also:** `Makefile`, `AGENTS.md`, `PROGRESS.md` added to `.chezmoiignore`. Without that, chezmoi would deploy them into `$HOME`.
- **Verification:** Alpine container with `install` removed: chezmoi installed via the shim, cleanup removed it. `gitleaks git`/`gitleaks dir` both clean. Hook blocked a staged fake `ghp_` token (exit 1). It did NOT catch an AWS `...EXAMPLE...` key, which gitleaks allowlists by default.
- **Not run:** full ing.sh end-to-end on a real router.
