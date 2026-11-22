SITE    := $(HOME)/workspace/lolf.art
PUB     := $(SITE)/public
SCRIPTS := ing.sh abc.sh

.PHONY: deploy
deploy:
	@changed=""; stamp="# modified: $$(date '+%Y-%m-%d %H:%M:%S %Z')"; \
	for f in $(SCRIPTS); do \
	  if grep -v '^# modified: ' $(PUB)/$$f 2>/dev/null | cmp -s dot_local/bin/$$f -; then echo "[deploy] $$f unchanged"; \
	  else { cat dot_local/bin/$$f; echo "$$stamp"; } > $(PUB)/$$f && echo "[deploy] $$f -> $(PUB)/$$f ($$stamp)" && changed="$$changed $$f"; fi; \
	done; \
	[ -n "$$changed" ] || { echo "[deploy] nothing to publish"; exit 0; }; \
	cd $(SITE) && git add $(addprefix public/,$(SCRIPTS)) && \
	git commit -qm "$${changed# }" && echo "[deploy] committed:$$changed" && \
	git push -q && echo "[deploy] pushed lolf.art"

.PHONY: hooks
hooks:
	@git config core.hooksPath .githooks && echo "[hooks] core.hooksPath -> .githooks (gitleaks pre-commit)"
