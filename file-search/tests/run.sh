#!/bin/sh
# The stock luau CLI has no io library, so the panel source is spliced into
# the test as a string and the two run as one chunk.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/file-search-panel-keys.luau"
{
    printf 'local PANEL_SRC = [==[\n'
    cat panel.luau
    printf '\n]==]\n'
    cat tests/panel_keys_test.lua
} > "$out"
luau "$out"
