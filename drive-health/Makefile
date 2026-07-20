SHELL := /bin/sh

.PHONY: test unit shell translations lint

test: unit shell translations lint

unit:
	lua tests/collector_harness.lua ready
	lua tests/collector_harness.lua missing-lsblk
	lua tests/collector_harness.lua missing-smartctl
	lua tests/collector_harness.lua incompatible-lsblk
	lua tests/collector_harness.lua incompatible-smartctl
	lua tests/collector_harness.lua async-incompatible-lsblk
	lua tests/collector_harness.lua probe-timeout
	lua tests/collector_harness.lua probe-completes-during-collection
	lua tests/collector_harness.lua raw-cache
	lua tests/collector_harness.lua outdated-raw-cache
	lua tests/collector_harness.lua legacy-raw-cache
	lua tests/collector_harness.lua collector-disabled
	lua tests/collector_harness.lua legacy-cache
	lua tests/alert_harness.lua
	lua tests/history_harness.lua
	lua tests/panel_harness.lua
	lua tests/widget_harness.lua

shell:
	sh tests/test_collect_raw.sh
	sh tests/test_packaging.sh
	sh -n scripts/collect_raw.sh packaging/smart-action.sh tests/test_collect_raw.sh tests/test_packaging.sh
	bash -n packaging/install-system-collector.sh packaging/uninstall-system-collector.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/collect_raw.sh packaging/*.sh tests/test_collect_raw.sh tests/test_packaging.sh tests/fixtures/bin/*; \
	fi

translations:
	jq empty translations/en.json

lint:
	@if command -v noctalia >/dev/null 2>&1; then noctalia plugins lint .; \
	else echo "noctalia CLI unavailable; skipped plugin manifest lint"; fi
	git diff --check
