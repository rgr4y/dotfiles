SITE    := $(HOME)/workspace/lolf.art
PUB     := $(SITE)/public
SCRIPTS := ing.sh abc.sh
WLOG    := /tmp/lolf-wrangler.log

# Idempotent "make sure lolf.art serves the current scripts":
#   copy changed scripts (stamped "# modified:"), commit + push lolf.art,
#   then wrangler deploy if any live script's stamp differs from the local copy.
.PHONY: deploy
deploy:
	@changed=""; stamp="# modified: $$(date '+%Y-%m-%d %H:%M:%S %Z')"; \
	for f in $(SCRIPTS); do \
	  if grep -v '^# modified: ' $(PUB)/$$f 2>/dev/null | cmp -s dot_local/bin/$$f -; then echo "[deploy] $$f unchanged"; \
	  else { cat dot_local/bin/$$f; echo "$$stamp"; } > $(PUB)/$$f && echo "[deploy] $$f -> $(PUB)/$$f ($$stamp)" && changed="$$changed $$f"; fi; \
	done; \
	cd $(SITE) || exit 1; \
	if [ -n "$$changed" ]; then \
	  git add $(addprefix public/,$(SCRIPTS)) && git commit -qm "$${changed# }" && echo "[deploy] committed:$$changed" || exit 1; \
	fi; \
	if [ -n "$$(git log --oneline @{u}..HEAD 2>/dev/null)" ]; then git push -q && echo "[deploy] pushed lolf.art" || exit 1; fi; \
	stale=""; \
	for f in $(SCRIPTS); do \
	  live="$$(curl -sL --max-time 15 "https://lolf.art/$$f?t=$$(date +%s)" | tail -1)"; \
	  [ "$$live" = "$$(tail -1 public/$$f)" ] || stale="$$stale $$f"; \
	done; \
	if [ -z "$$stale" ]; then echo "[deploy] live ✓ (all scripts match)"; exit 0; fi; \
	echo "[deploy] stale on lolf.art:$$stale — wrangler deploy..."; \
	timeout 120 npm run -s deploy >$(WLOG) 2>&1 || { echo "[deploy] wrangler FAILED — see $(WLOG)"; exit 1; }; \
	for f in $$stale; do \
	  live="$$(curl -sL --max-time 15 "https://lolf.art/$$f?t=$$(date +%s)" | tail -1)"; \
	  if [ "$$live" = "$$(tail -1 public/$$f)" ]; then echo "[deploy] live ✓ $$f ($$live)"; \
	  else echo "[deploy] WARNING: live $$f still '$$live'"; fi; \
	done

.PHONY: hooks
hooks:
	@git config core.hooksPath .githooks && echo "[hooks] core.hooksPath -> .githooks (gitleaks pre-commit)"
