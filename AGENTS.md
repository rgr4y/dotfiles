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

## Shipping `ing.sh` / `abc.sh`

Devices bootstrap with `curl -sL lolf.art/ing.sh | sh`, so lolf.art must serve the
current scripts.

- After changing either script: commit, `git push`, then `make`. Don't stop at the
  commit and hand the rest back.
- `make` is idempotent. It copies changed scripts to `~/workspace/lolf.art/public/`
  (adds a `# modified:` stamp as the last line), commits and pushes lolf.art, checks
  the live stamps, and runs `wrangler deploy` if anything on lolf.art is stale.
- **Before ending a session, always run `make` and confirm it prints `live ✓`.**
  Do this even if you didn't touch the scripts this session.
- Manual check: `curl -sL lolf.art/ing.sh | tail -1` should equal
  `tail -1 ~/workspace/lolf.art/public/ing.sh`.
