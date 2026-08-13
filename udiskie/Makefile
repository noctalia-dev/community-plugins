SHELL := /bin/sh

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
	python3 ../.github/workflows/scripts/validate-plugins.py && echo "✓ Official repo manifest validation passed"
	git diff --check
