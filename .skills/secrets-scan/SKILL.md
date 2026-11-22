---
name: secrets-scan
description: Scan this public dotfiles repo for leaked secrets (staged, history, working tree), triage findings, and respond to a real leak.
---

# Secrets scan

This repo is public (GitHub + lolf.art serves `ing.sh`/`abc.sh`). Treat any hit as
published until proven otherwise.

## 1. Scan

Run from the repo root. Always pass `--redact` so secrets never land in logs or chat.

| What | Command |
|------|---------|
| Staged changes (what the hook runs) | `gitleaks git --pre-commit --staged --redact -v` |
| Full git history | `gitleaks git --redact -v .` |
| Unpushed commits only | `gitleaks git --redact -v --log-opts="origin/main..HEAD" .` |
| Working tree incl. untracked | `gitleaks dir --redact -v .` |

`gitleaks dir` also scans gitignored files. `.idea/` is allowlisted in `.gitleaks.toml`.
For other ignored paths, confirm with `git ls-files <path>`: if it isn't tracked, it
isn't published.

## 2. Triage each finding

1. Read the line with the value masked, e.g.
   `git show <commit>:<file> | sed -n '<line>p'`. Never paste the raw value anywhere.
2. Decide: real credential, or false positive (help text, IDs, example values).
3. False positive: add an `[[allowlists]]` entry to `.gitleaks.toml` with a
   `description` saying why. Scope it tight: `commits` + `paths` with
   `condition = "AND"` for history hits, or a `regexes` match on the exact value shape.
   Don't use `.gitleaksignore`: a fingerprint line trips `generic-api-key` itself in
   `gitleaks dir` scans.

## 3. Real leak

Order matters. Rotation comes first because history rewrites don't unpublish anything.

1. **Rotate/revoke** the credential at its provider. Now.
2. Remove it from the working tree. Load it at runtime instead (env var, `~/.secrets`,
   1Password CLI, chezmoi template reading from a password manager).
3. If it was pushed: history rewrite (`git filter-repo --replace-text`) + force push.
   **Needs Rob's explicit OK** — never force push on your own.
4. If `ing.sh`/`abc.sh` carried it: `make` to republish the cleaned copy to lolf.art.

## Setup

`make hooks` points `core.hooksPath` at `.githooks/`. That overrides the global
`~/.git-hooks` (git-lfs only; this repo has no LFS).
