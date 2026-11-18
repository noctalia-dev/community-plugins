#!/usr/bin/env bash
# All checks: Luau modules, the service against a fake host, the generated
# file through Hyprland's luac, txn.lua.
set -e
cd "$(dirname "$0")/.."
mkdir -p tests/.build
for f in service panel widget launcher; do
  { printf 'return [==[\n'; cat $f.luau; printf ']==]\n'; } > tests/.build/${f}_src.luau
done
cat > tests/.build/syntax.luau <<'LUA'
for _, f in ipairs({ "panel", "widget", "launcher" }) do
  assert(loadstring(require("./" .. f .. "_src"), f .. ".luau"))
  print("ok   " .. f .. ".luau compiles")
end
LUA
luau tests/.build/syntax.luau
luau tests/run.luau
luau tests/service_test.luau
luau tests/sample.luau | luac -p - && echo "ok   generated file passes luac -p"
bash tests/txn_test.sh
bash tests/setup_test.sh
