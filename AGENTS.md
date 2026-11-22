# AGENTS.md

## This repo is public

Everything committed here is world-readable on GitHub. `ing.sh` and `abc.sh` are also
served from lolf.art via `make`.

- Never commit credentials, tokens, private keys, internal hostnames, or customer data.
  Load secrets at runtime (env, password manager, chezmoi templates).
- Pre-commit hook runs gitleaks on staged changes. Enable once per clone: `make hooks`.
- Don't bypass the hook (`--no-verify`) to get past a finding. Triage it.
- Scan / triage / leak-response procedure: `.skills/secrets-scan/SKILL.md`.

## chezmoi

Non-dot files at the repo root get deployed into `$HOME` unless listed in
`.chezmoiignore`. Add any new repo-only file there (e.g. `Makefile`, `AGENTS.md`).
