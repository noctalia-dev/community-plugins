SHELL := /bin/sh
VALIDATOR ?= ../../official-plugins/.github/actions/validate-plugins/validate-plugins.py

.PHONY: test translations lint

test: translations lint

translations:
	@if command -v jq >/dev/null 2>&1; then \
		jq empty translations/en.json && echo "✓ translations/en.json is valid JSON"; \
	fi
	python3 tests/check_translations.py

lint:
	@if command -v noctalia >/dev/null 2>&1; then \
		noctalia plugins lint . && echo "✓ Noctalia plugin lint passed"; \
	fi
	@test -f "$(VALIDATOR)" || { echo "Set VALIDATOR to the shared validate-plugins.py; see ../README.md for setup." >&2; exit 1; }
	python3 "$(VALIDATOR)" --profile community --root .. && echo "✓ Community repo manifest validation passed"
	git diff --check
