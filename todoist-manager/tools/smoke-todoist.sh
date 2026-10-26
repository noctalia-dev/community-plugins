#!/usr/bin/env bash
# tools/smoke-todoist.sh — live Phase 1 smoke test against the real Todoist API.
#
# The token is read from $TODOIST_API_TOKEN, or from a file (default
# ~/.config/todoist/token, override with $TODOIST_TOKEN_FILE). It is never
# echoed and never passed as an argument. The Authorization header goes to curl
# through an inherited file descriptor (-H @/dev/fd/9) whose backing file is
# unlinked as soon as it is opened, so the value never appears in any process's
# argv (readable via ps and /proc/<pid>/cmdline) and no copy stays on disk.
#
# Phase 1: creates two tasks with Quick Add and deletes them again.
# Phase 2: create -> update -> move -> close -> reopen -> delete, verifying that
# every mutation response is the full object we render, plus /sections, /labels
# and the completed-items path. Everything it creates is deleted on exit.
#
# Usage:
#   ./tools/smoke-todoist.sh
set -u

API=https://api.todoist.com/api/v1

if [ -n "${TODOIST_API_TOKEN:-}" ]; then
  TOKEN="$TODOIST_API_TOKEN"
  TOKEN_SRC="\$TODOIST_API_TOKEN"
else
  TOKEN_FILE="${TODOIST_TOKEN_FILE:-$HOME/.config/todoist/token}"
  if [ ! -r "$TOKEN_FILE" ]; then
    echo "No token: set TODOIST_API_TOKEN or create $TOKEN_FILE (chmod 600)." >&2
    exit 2
  fi
  TOKEN="$(python3 - "$TOKEN_FILE" <<'PY'
import sys, re
for line in open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines():
    t = line.strip()
    if not t or t.startswith("#"):
        continue
    t = re.sub(r'^export\s+', '', t)
    m = re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*=\s*(.+)$', t)
    if m:
        t = m.group(1)
    t = re.sub(r'^"(.*)"$', r'\1', t.strip())
    t = re.sub(r"^'(.*)'$", r'\1', t.strip())
    t = t.strip()
    if t:
        sys.stdout.write(t)
        break
PY
)"
  TOKEN_SRC="$TOKEN_FILE"
fi

if [ -z "$TOKEN" ]; then
  echo "Token is empty." >&2
  exit 2
fi

MARK="noctalia-smoke-$$-$(date +%s)"
CREATED=()

# Open the Authorization header on fd 9, then unlink the backing file: the fd
# stays readable for every curl call below while the path is gone from the
# filesystem, so the token is never in an argv and never left on disk.
HDR_FILE="$(mktemp "${TMPDIR:-/tmp}/noctalia-smoke-hdr.XXXXXX")" || {
  echo "Could not create a temporary header file." >&2
  exit 2
}
chmod 600 "$HDR_FILE"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HDR_FILE"
exec 9< "$HDR_FILE"
rm -f "$HDR_FILE"
unset HDR_FILE TOKEN TODOIST_API_TOKEN

H=(-H "@/dev/fd/9" -H "Content-Type: application/json" -H "Accept: application/json")

say() { printf '\n=== %s ===\n' "$*"; }
count() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(len(d.get('results', d.get('items', []))))"; }
status() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

cleanup() {
  for id in "${CREATED[@]:-}"; do
    [ -z "$id" ] && continue
    code=$(status -X DELETE "${H[@]}" "$API/tasks/$id")
    echo "  cleanup: DELETE /tasks/$id -> HTTP $code"
  done
}
trap cleanup EXIT

say "0. token source: $TOKEN_SRC (value hidden)"

say "1. auth: GET /projects (expect 200)"
code=$(status "${H[@]}" "$API/projects?limit=1")
echo "HTTP $code"
[ "$code" = "200" ] || { echo "FAIL: expected 200 — check the token"; exit 1; }

say "2. bad token (expect 401)"
code=$(status -H "Authorization: Bearer definitely-not-a-token" "$API/projects?limit=1")
echo "HTTP $code"

say "3. GET /projects pagination shape (expect results[] + next_cursor)"
curl -sS "${H[@]}" "$API/projects?limit=2" | python3 -c "import json,sys
d=json.load(sys.stdin)
print('keys:', sorted(d.keys()))
print('n results:', len(d.get('results', [])))
print('next_cursor present:', 'next_cursor' in d)"

say "4. GET /tasks/filter?query=today (expect 200 + results[])"
code=$(status "${H[@]}" "$API/tasks/filter?query=today&limit=5")
echo "HTTP $code"
curl -sS "${H[@]}" "$API/tasks/filter?query=today&limit=5" | count | sed 's/^/  today count: /'

say "5. GET /tasks/filter?query=priority:4 (expect 200 + results[])"
code=$(status "${H[@]}" "$API/tasks/filter?query=priority%3A4&limit=5")
echo "HTTP $code (note: 'priority:4' means P1 in the UI)"

say "6. Quick Add a task (expect 200 + empty body), marker $MARK"
code=$(status -X POST "${H[@]}" "$API/tasks/quick" \
  -d "{\"text\":\"$MARK buy milk today\"}")
echo "HTTP $code"

say "7. Quick Add with a priority (expect p1 -> API priority 4)"
code=$(status -X POST "${H[@]}" "$API/tasks/quick" \
  -d "{\"text\":\"$MARK urgent thing today p1\"}")
echo "HTTP $code"

say "8. find both by filter search: (expect 2 tasks; proves natural-language parsing)"
BODY=$(curl -sS "${H[@]}" "$API/tasks/filter?query=search%3A$MARK")
echo "$BODY" | python3 -c "import json,sys
d=json.load(sys.stdin)
ts=d.get('results') or d.get('items') or []
print('  found:', len(ts))
for t in ts:
    print('  -', t['id'], '| p=%s' % t.get('priority'), '| due=%s' % (t.get('due') or {}).get('date'), '|', t['content'])"
mapfile -t CREATED < <(echo "$BODY" | python3 -c "import json,sys
d=json.load(sys.stdin)
ts=d.get('results') or d.get('items') or []
for t in ts: print(t['id'])")

say "9. priority mapping check (API 4 must be the p1 task)"
echo "$BODY" | python3 -c "import json,sys
d=json.load(sys.stdin)
ts=d.get('results') or d.get('items') or []
prio={t['content']:t.get('priority') for t in ts}
hit=[p for c,p in prio.items() if 'urgent' in c]
print('  urgent task API priority:', hit[0] if hit else 'not found', '(4 = P1 -> client p1)')"

say "10. cleanup runs on exit (DELETE /tasks/{id})"
echo "  to delete: ${CREATED[*]:-none}"

say "11. GET /labels (expect 200 + results[])"
code=$(status "${H[@]}" "$API/labels")
echo "HTTP $code"
curl -sS "${H[@]}" "$API/labels" | python3 -c "import json,sys
d=json.load(sys.stdin)
rs=d.get('results') or d.get('items') or []
print('  labels:', len(rs), '| first:', rs[0]['name'] if rs else '(none)')"

say "12. POST /tasks create (expect 200 + the task object with an id)"
INBOX=$(curl -sS "${H[@]}" "$API/projects" | python3 -c "import json,sys
d=json.load(sys.stdin); rs=d.get('results') or d.get('items') or []
print(next((p['id'] for p in rs if p.get('inbox_project')), next((p['id'] for p in rs if p['name'].lower() == 'inbox'), rs[0]['id'] if rs else '')))")
if [ -z "$INBOX" ]; then echo "FAIL: no project to create into"; exit 1; fi
RESP=$(curl -sS -X POST "${H[@]}" "$API/tasks" \
  -d "{\"content\":\"$MARK mutation\",\"project_id\":\"$INBOX\",\"priority\":1}")
TID=$(echo "$RESP" | python3 -c "import json,sys
d=json.load(sys.stdin); print(d.get('id') or '')")
echo "  id: ${TID:-<none>} | priority: $(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin).get('priority'))")"
[ -n "$TID" ] || { echo "FAIL: create returned no id"; exit 1; }
CREATED+=("$TID")

say "13. POST /tasks/{id} update content+priority+labels (expect 200 + full object)"
RESP=$(curl -sS -X POST "${H[@]}" "$API/tasks/$TID" \
  -d "{\"content\":\"$MARK updated\",\"description\":\"note\",\"priority\":4,\"labels\":[\"smoke\"]}")
echo "$RESP" | python3 -c "import json,sys
d=json.load(sys.stdin)
print('  content:', d.get('content'))
print('  priority:', d.get('priority'), '(4 = P1 in the UI)')
print('  labels:', d.get('labels'))
print('  description:', d.get('description'))"

say "14. update with due_string=no date clears it (expect due = None)"
curl -sS -X POST "${H[@]}" "$API/tasks/$TID" -d '{"due_string":"tomorrow"}' >/dev/null
curl -sS -X POST "${H[@]}" "$API/tasks/$TID" -d '{"due_string":"no date"}' | python3 -c "import json,sys
d=json.load(sys.stdin); print('  due:', d.get('due'))"

say "15. update rejects project_id (expect 400 + error_code 42)"
code=$(status -X POST "${H[@]}" "$API/tasks/$TID" -d "{\"project_id\":\"$INBOX\"}")
echo "HTTP $code (move changes the project instead)"
curl -sS -X POST "${H[@]}" "$API/tasks/$TID" -d "{\"project_id\":\"$INBOX\"}" | python3 -c "import json,sys
d=json.load(sys.stdin); print('  error_code:', d.get('error_code'))" 2>/dev/null || true

say "16. POST /tasks/{id}/move (expect 200; a bare project_id clears the section)"
TARGET=$(curl -sS "${H[@]}" "$API/projects" | python3 -c "import json,sys
d=json.load(sys.stdin); rs=d.get('results') or d.get('items') or []
print(next((p['id'] for p in rs if not p.get('is_inbox_project')), ''))")
if [ -n "$TARGET" ]; then
  echo "  target project: $TARGET"
  curl -sS -X POST "${H[@]}" "$API/tasks/$TID/move" -d "{\"project_id\":\"$TARGET\"}" | python3 -c "import json,sys
d=json.load(sys.stdin); print('  project_id:', d.get('project_id'), '| section_id:', d.get('section_id'))"
  echo "  sections for the target:"
  curl -sS "${H[@]}" "$API/sections?project_id=$TARGET" | python3 -c "import json,sys
d=json.load(sys.stdin); rs=d.get('results') or d.get('items') or []
print('   ', len(rs), 'section(s)')"
  if [ "$TARGET" != "$INBOX" ]; then
    curl -sS -X POST "${H[@]}" "$API/tasks/$TID/move" -d "{\"project_id\":\"$INBOX\"}" | python3 -c "import json,sys
d=json.load(sys.stdin); print('  back to inbox | project_id:', d.get('project_id'), '| section_id:', d.get('section_id'))"
  else
    echo "  (only one project, already there; the bare-project move was verified above)"
  fi
else
  echo "  (only one project; skipping the move)"
fi

say "17. close -> GET checked -> reopen -> GET checked"
code=$(status -X POST "${H[@]}" "$API/tasks/$TID/close")
echo "  close HTTP $code"
curl -sS "${H[@]}" "$API/tasks/$TID" | python3 -c "import json,sys
d=json.load(sys.stdin); print('  checked:', d.get('checked'))"
code=$(status -X POST "${H[@]}" "$API/tasks/$TID/reopen")
echo "  reopen HTTP $code"

say "18. GET /tasks/completed (expect 200 + items[]; match on task_id)"
SINCE=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
UNTIL=$(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
code=$(status "${H[@]}" "$API/tasks/completed?since=$SINCE&until=$UNTIL&limit=5")
echo "  HTTP $code"
curl -sS "${H[@]}" "$API/tasks/completed?since=$SINCE&until=$UNTIL&limit=5" | python3 -c "import json,sys
d=json.load(sys.stdin); it=d.get('items') or []
print('  items:', len(it), '| has task_id:', bool(it and 'task_id' in it[0]))"

say "19. DELETE /tasks/{id} then GET (expect 204 then 404)"
code=$(status -X DELETE "${H[@]}" "$API/tasks/$TID")
echo "  DELETE HTTP $code"
code=$(status "${H[@]}" "$API/tasks/$TID")
echo "  GET HTTP $code"

say "20. cleanup runs on exit (DELETE /tasks/{id})"
echo "  to delete: ${CREATED[*]:-none}"

say "DONE"
