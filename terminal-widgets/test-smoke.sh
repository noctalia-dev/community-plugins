#!/usr/bin/env bash
# Prueba de humo del plugin `faminec/terminal-widgets` sobre el escritorio.
#
# Necesita Hyprland con Noctalia y el plugin activados. Abre el panel, lanza
# todos los widgets, comprueba que están todos, los rota, comprueba que las
# posiciones se permutan, los cierra y cierra el panel. Al final revisa
# **todas** las líneas nuevas del log desde el primer al último paso, también
# si la prueba falla antes, y falla si hay cualquier [WRN] o [ERR], sea del
# plugin o no.
#
#   ./test-smoke.sh                  # usa el plugin instalado
#   ./test-smoke.sh /ruta/otra       # usa el manifiesto de otra copia
#
# Sale con código distinto de 0 si algo falla.
#
# Variables: NOCTALIA_LOG (ruta del log), OPEN_TIMEOUT, ROTATE_TIMEOUT,
# CLOSE_TIMEOUT (segundos de espera máxima de cada paso).

set -u

PLUGIN_ID="faminec/terminal-widgets"
PANEL="$PLUGIN_ID:panel"
PLUGIN_DIR="${1:-$HOME/.local/share/noctalia/plugins/terminal-widgets}"
LOG="${NOCTALIA_LOG:-$HOME/.cache/noctalia/noctalia.log}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia"
STORE="$STATE_DIR/plugins/data/$PLUGIN_ID/store.json"

OPEN_TIMEOUT="${OPEN_TIMEOUT:-45}"
ROTATE_TIMEOUT="${ROTATE_TIMEOUT:-15}"
CLOSE_TIMEOUT="${CLOSE_TIMEOUT:-20}"
# Margen tras abrir para que se note un comando que termina solo y se lleva su
# ventana por delante (`cbonsai -l -p` tardaba ~7 s en imprimir y salir).
SETTLE="${SETTLE:-8}"

LOG_READY=0
LOG_CHECKED=0
FOLLOWER_PID=""
tmp=""

stop_follower() {
  if [ -n "$FOLLOWER_PID" ]; then
    kill "$FOLLOWER_PID" 2>/dev/null || true
    wait "$FOLLOWER_PID" 2>/dev/null || true
    FOLLOWER_PID=""
  fi
}

cleanup() {
  stop_follower
  if [ -n "$tmp" ]; then
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

fail() {
  echo "FALLA: $*" >&2
  # Aunque la prueba se corte a medias, las líneas nuevas del log se revisan
  # igualmente: un fallo no puede ocultar avisos o errores.
  if [ "$LOG_READY" -eq 1 ] && [ "$LOG_CHECKED" -eq 0 ]; then
    # Volcar antes de revisar: si no, las últimas líneas del plugin pueden
    # seguir en el búfer del host y el fallo quedaría sin contexto.
    if [ -n "$FOLLOWER_PID" ]; then
      flush_log >/dev/null 2>&1 || true
      stop_follower
    fi
    echo "--- [WRN]/[ERR] nuevas en el log hasta el fallo ---" >&2
    review_log >&2 || true
  fi
  exit 1
}

if ! command -v noctalia >/dev/null 2>&1; then
  echo "noctalia no está en el PATH; esta prueba necesita el escritorio" >&2
  exit 2
fi

if ! command -v hyprctl >/dev/null 2>&1; then
  echo "hyprctl no está en el PATH; esta prueba necesita Hyprland" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 no está en el PATH; hace falta para leer la configuración" >&2
  exit 2
fi

[ -f "$PLUGIN_DIR/plugin.toml" ] || fail "no encuentro el manifiesto en $PLUGIN_DIR/plugin.toml"

# Número de widgets que deben acabar abiertos: los comandos no vacíos que
# resultan de fusionar los defaults (manifiesto o respaldo de lib/defaults.luau)
# y el store del panel, menos los borrados. Es la misma precedencia que usa
# `lib/store.luau`; los Ajustes de Noctalia ya no participan.
expected_line=$(python3 - "$PLUGIN_DIR/plugin.toml" "$STORE" <<'PY'
import json
import os
import re
import sys
import tomllib

manifest_path, store_path = sys.argv[1:3]
plugin_dir = os.path.dirname(manifest_path)

base = {}
with open(manifest_path, "rb") as handle:
    manifest = tomllib.load(handle)
for setting in manifest.get("setting", []):
    if setting.get("key") == "commands" and isinstance(setting.get("default"), dict):
        base = setting["default"]

# Si el manifiesto ya no lleva los comandos, el plugin usa la tabla de respaldo
# de lib/defaults.luau. Se lee aquí para que la prueba calcule lo mismo.
if not base:
    defaults_path = os.path.join(plugin_dir, "lib", "defaults.luau")
    try:
        with open(defaults_path, encoding="utf-8") as handle:
            text = handle.read()
        block = re.search(r"FALLBACK_COMMANDS\s*=\s*\{(.*?)\}", text, re.S)
        if block:
            base = dict(re.findall(r'([A-Za-z0-9_%-]+)\s*=\s*"([^"]*)"', block.group(1)))
    except FileNotFoundError:
        pass

store = {}
try:
    with open(store_path, encoding="utf-8") as handle:
        store = json.load(handle)
except FileNotFoundError:
    pass

commands = {name: value for name, value in base.items() if isinstance(value, str) and value}
commands.update({name: value for name, value in (store.get("commands") or {}).items() if isinstance(value, str)})
for name in store.get("removed") or []:
    commands.pop(name, None)

names = sorted(name for name, value in commands.items() if value)
print(len(names), " ".join(names))
PY
) || fail "no se pudo leer la configuración de widgets"
read -r expected names <<<"$expected_line"
[ "$expected" -ge 1 ] || fail "no hay ningún widget configurado"
echo "widgets esperados: $expected ($names)"

# El host rota/trunca `noctalia.log` y sus líneas del script-runtime pueden
# tardar en volcarse. `tail -F` sigue el fichero (aunque lo renombren o lo
# vacíen) y deja una copia privada con todas las líneas nuevas; el smoke
# revisa esa copia, no el fichero volátil.
#
# Cerrar paneles de otras sesiones para reducir la carga del host durante la
# prueba (acción de runtime, no toca código de otros plugins; sus timers los
# reabren). Se puede desactivar con CLOSE_FOREIGN_PANELS=0.
if [ "${CLOSE_FOREIGN_PANELS:-1}" != "0" ]; then
  for p in faminec/wallpaper-carousel:panel faminec/lyrics-carousel:panel \
           faminec/notes:panel faminec/notes-sync:panel \
           faminec/cmf-buds:panel faminec/cmf-buds:panel-sound; do
    noctalia msg panel-close "$p" >/dev/null 2>&1 || true
  done
fi

# Antes de capturar nada se espera a que el host esté inactivo (10 s sin
# crecimiento del log): si no, la prueba arrastra ruido de otras sesiones y
# puede provocar avisos de rendimiento del propio host.
echo "esperando a que el host esté inactivo (hasta 60 s)..."
last=0; stable=0; iters=0
if [ -f "$LOG" ]; then
  last=$(wc -l <"$LOG")
fi
while [ "$stable" -lt 50 ] && [ "$iters" -lt 300 ]; do
  sleep 0.2
  iters=$((iters + 1))
  if [ -f "$LOG" ]; then
    cur=$(wc -l <"$LOG")
  else
    cur=0
  fi
  if [ "$cur" -eq "$last" ]; then
    stable=$((stable + 1))
  else
    stable=0
    last=$cur
  fi
done
echo "host inactivo; iniciando la prueba."

tmp=$(mktemp -d /tmp/opencode/terminal-widgets-smoke.XXXXXX) || {
  echo "no se pudo crear el directorio temporal" >&2
  exit 2
}
# Seguidor robusto: drena el fichero viejo hasta el final antes de cambiar al
# nuevo cuando el host rota/trunca el log (tail -F puede perder líneas).
python3 - "$LOG" "$tmp/run.log" <<'PY' &
import os
import sys
import time

log, out = sys.argv[1], sys.argv[2]
f = open(out, "ab", buffering=0)
fh = None
inode = None
try:
    fh = open(log, "rb")
    fh.seek(0, os.SEEK_END)
    inode = os.fstat(fh.fileno()).st_ino
except FileNotFoundError:
    fh = None
    inode = None

while True:
    time.sleep(0.1)
    try:
        st = os.stat(log)
    except FileNotFoundError:
        continue
    if fh is None or st.st_ino != inode:
        if fh is not None:
            # Drenar el fichero viejo hasta el final; el host puede escribir
            # la línea de cierre justo después de rotar, así que se relee una
            # vez más tras una espera corta.
            for _ in range(2):
                try:
                    data = fh.read()
                    if data:
                        f.write(data)
                except Exception:
                    pass
                time.sleep(0.2)
            try:
                fh.close()
            except Exception:
                pass
        try:
            fh = open(log, "rb")
            inode = os.fstat(fh.fileno()).st_ino
            fh.seek(0, os.SEEK_END)
        except FileNotFoundError:
            fh = None
            inode = None
            continue
    try:
        pos = fh.tell()
        size = os.fstat(fh.fileno()).st_size
    except Exception:
        continue
    if pos > size:
        fh.seek(0)
    try:
        data = fh.read()
    except Exception:
        continue
    if data:
        f.write(data)
PY
FOLLOWER_PID=$!
sleep 0.2

# Espera hasta $2 s a que $tmp/run.log deje de crecer $1 s seguidos (sin
# actividad nueva). Devuelve 0 siempre: es una espera de estabilidad, no un
# criterio de éxito.
wait_log_quiet() {
  local quiet="${1:-1}"
  local max="${2:-5}"
  local deadline=$((SECONDS + max)) last cur stable=0
  last=$(wc -l <"$tmp/run.log" 2>/dev/null || echo 0)
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.2
    cur=$(wc -l <"$tmp/run.log" 2>/dev/null || echo 0)
    if [ "$cur" -eq "$last" ]; then
      stable=$((stable + 1))
      if [ "$stable" -ge $((quiet * 5)) ]; then
        return 0
      fi
    else
      stable=0
      last="$cur"
    fi
  done
  return 0
}

# Punto de partida estable: se espera a que el log deje de crecer un segundo,
# para que la revisión no arrastre ruido de la pasada anterior ni del arranque.
wait_log_quiet 5 25
LOG_READY=1

# Revisa todas las líneas nuevas del log (la copia), sin excluir ningún
# patrón: cualquier [WRN] o [ERR] hace fallar la prueba, sea del plugin o no.
review_log() {
  local total plugin_lines problems
  if [ ! -f "$tmp/run.log" ]; then
    echo "   (no hay copia del log; no se puede comprobar)" >&2
    return 1
  fi
  total=$(wc -l <"$tmp/run.log")
  # El conteo estable es el del plugin (líneas propias + panel + recarga +
  # hot-reload); el host añade ruido ajeno que varía entre pasadas. La
  # revisión de [WRN]/[ERR] se hace sobre TODAS las líneas, sin filtrar.
  plugin_lines=$(grep -c -E "terminal-widgets|panel\.luau'" "$tmp/run.log" 2>/dev/null || true)
  [ -n "$plugin_lines" ] || plugin_lines=0
  problems=$(grep -E "\[WRN\]|\[ERR\]" "$tmp/run.log" || true)
  if [ -n "$problems" ]; then
    echo "   $total líneas del host ($plugin_lines del plugin); avisos/errores encontrados:" >&2
    printf '%s\n' "$problems" >&2
    return 1
  fi
  echo "   $total líneas del host revisadas ($plugin_lines del plugin); ningún [WRN]/[ERR] ✔"
  return 0
}

# Espera hasta $2 segundos a que aparezca $1 en las líneas nuevas de $3
# (la copia del log) desde la marca $4. Las líneas nativas del host se
# escriben al momento; las del script-runtime pueden seguir en el búfer.
wait_log_line() {
  local pattern="$1" deadline=$((SECONDS + ${2:-2})) file="${3:-$tmp/run.log}" mark="${4:-0}"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f "$file" ] && tail -n +"$((mark + 1))" "$file" | grep -q "$pattern"; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

# El host escribe los logs del script-runtime en un búfer y puede tardar
# decenas de segundos en volcarlos al fichero. `log-level-set` con el nivel
# actual es un no-op que escribe una línea nativa y vacía ese búfer; se espera
# a ver esa línea en la copia para no revisar un log incompleto.
flush_log() {
  local level mark deadline
  level=$(noctalia msg log-level-status 2>/dev/null) || return 1
  [ -n "$level" ] || return 1
  mark=$(wc -l <"$tmp/run.log" 2>/dev/null || echo 0)
  deadline=$((SECONDS + 12))
  # El host puede tardar varios segundos en procesar la cola: se reintenta y
  # se espera a que cualquiera de las líneas nativas llegue a la copia. Como
  # van detrás de las del plugin, ver una implica que esas también se
  # volcaron.
  while [ "$SECONDS" -lt "$deadline" ]; do
    noctalia msg log-level-set "$level" >/dev/null 2>&1 || return 1
    if wait_log_line "log level set to $level" 2 "$tmp/run.log" "$mark"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

plugin_geometry() {
  hyprctl clients -j 2>/dev/null | python3 -c '
import json
import sys

try:
    clients = json.load(sys.stdin)
except Exception:
    clients = []

for client in sorted(
    (c for c in clients if c.get("class", "").startswith("noctalia-term-")),
    key=lambda c: c.get("class", ""),
):
    at = client.get("at") or [0, 0]
    print(client.get("class", ""), int(at[0]), int(at[1]))
'
}

plugin_count() {
  plugin_geometry | grep -c . || true
}

# Espera a que haya exactamente $1 ventanas del plugin, hasta $2 segundos.
wait_count() {
  local target="$1" deadline=$((SECONDS + $2))
  while :; do
    [ "$(plugin_count)" -eq "$target" ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.3
  done
}

# Espera a que la geometría deje de cambiar durante ~1 s. El contador llega a
# su número en cuanto la ventana existe, pero el plugin coloca y redimensiona
# un instante después: sin esto, el "antes" de la rotación sería una foto a
# medio colocar y la permutación no cuadraría.
wait_stable() {
  local deadline=$((SECONDS + 10)) previous current stable=0
  previous=$(plugin_geometry)
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.4
    current=$(plugin_geometry)
    if [ "$current" = "$previous" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 2 ] && return 0
    else
      stable=0
      previous="$current"
    fi
  done
  return 1
}

# Panel activo según el host. Es la única fuente fiable: otro plugin puede
# robar el foco y el log puede tardar segundos en volcarse.
active_panel() {
  noctalia msg status 2>/dev/null | python3 -c '
import json
import sys

try:
    print(json.load(sys.stdin).get("activePanelId") or "")
except Exception:
    print("")
'
}

# El panel solo atiende el IPC cuando está abierto y activo. `panel-open` es
# idempotente: si ya está abierto lo reactiva. Se comprueba en el estado real
# del host, no en el log.
ensure_panel() {
  local active deadline
  active=$(active_panel)
  if [ "$active" = "$PANEL" ]; then
    return 0
  fi
  noctalia msg panel-open "$PANEL" >/dev/null 2>&1 || fail "el panel no se pudo abrir"
  deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    active=$(active_panel)
    if [ "$active" = "$PANEL" ]; then
      return 0
    fi
    sleep 0.15
  done
  fail "el panel no quedó activo (activo: ${active:-ninguno})"
}

# Envía un evento al panel y reintenta si otro panel le robó el foco justo
# antes: `ensure_panel` lo reactiva y se vuelve a enviar.
plugin_ipc() {
  local event="$1" tries=3
  while [ "$tries" -gt 0 ]; do
    ensure_panel
    if noctalia msg plugin "$PANEL" all "$event" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.2
  done
  return 1
}

# El plugin analiza `plugin.toml` una vez y lo guarda en memoria; el host solo
# recarga el script cuando cambia un `.luau`, no cuando cambia el manifiesto.
# Se toca el mtime del panel instalado (sin cambiar su contenido) para que la
# prueba arranque con los comandos que hay ahora mismo en disco.
INSTALLED_PANEL="$HOME/.local/share/noctalia/plugins/terminal-widgets/panel.luau"
if [ -f "$INSTALLED_PANEL" ]; then
  touch "$INSTALLED_PANEL"
  sleep 1.5
fi

echo "0) partir de cero"
plugin_ipc close-all || fail "el IPC close-all no respondió"
wait_count 0 "$CLOSE_TIMEOUT" || fail "quedaron ventanas abiertas al empezar: $(plugin_geometry)"

echo "1) abrir todos los widgets"
opened=0
for attempt in 1 2 3; do
  plugin_ipc open-all || fail "el IPC open-all no respondió"
  if wait_count "$expected" 15; then
    opened=1
    break
  fi
  echo "   intento $attempt: $(plugin_count) de $expected ventanas" >&2
  sleep 2
done
if [ "$opened" -ne 1 ]; then
  echo "   abiertas: $(plugin_geometry | tr '\n' ' ')" >&2
  fail "se esperaban $expected ventanas y hay $(plugin_count)"
fi
wait_stable || fail "las ventanas no terminaron de colocarse"
sleep "$SETTLE"
if [ "$(plugin_count)" -ne "$expected" ]; then
  echo "   abiertas tras ${SETTLE}s: $(plugin_geometry | tr '\n' ' ')" >&2
  fail "algún widget se cerró solo (quedan $(plugin_count) de $expected)"
fi
echo "   ventanas abiertas: $(plugin_count) ✔"

echo "2) rotar"
cat >"$tmp/check_rotation.py" <<'PY'
import sys


def load(path):
    out = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) == 3:
                out[parts[0]] = (int(parts[1]), int(parts[2]))
    return out


before = load(sys.argv[1])
after = load(sys.argv[2])
if set(before) != set(after):
    print("las ventanas abiertas cambiaron al rotar", file=sys.stderr)
    sys.exit(1)
if sorted(before.values()) != sorted(after.values()):
    print("la rotación no fue una permutación de posiciones", file=sys.stderr)
    sys.exit(1)
if before == after:
    print("ninguna ventana cambió de posición", file=sys.stderr)
    sys.exit(1)
print(
    "permutación: "
    + ", ".join(
        f"{name}: {before[name]} -> {after[name]}"
        for name in sorted(before)
        if before[name] != after[name]
    )
)
PY
ensure_panel
plugin_geometry >"$tmp/before"
plugin_ipc rotate || fail "el IPC rotate no respondió"
deadline=$((SECONDS + ROTATE_TIMEOUT))
rotated=0
while [ "$SECONDS" -lt "$deadline" ]; do
  plugin_geometry >"$tmp/after"
  if python3 "$tmp/check_rotation.py" "$tmp/before" "$tmp/after" >"$tmp/check" 2>&1; then
    rotated=1
    break
  fi
  sleep 0.3
done
if [ "$rotated" -ne 1 ]; then
  cat "$tmp/check" >&2
  echo "   antes:" >&2
  sed 's/^/     /' "$tmp/before" >&2
  echo "   después:" >&2
  sed 's/^/     /' "$tmp/after" >&2
  fail "la rotación no permutó las posiciones de las ventanas"
fi
cat "$tmp/check"

echo "3) cerrar todas"
plugin_ipc close-all || fail "el IPC close-all no respondió"
if ! wait_count 0 "$CLOSE_TIMEOUT"; then
  echo "   restantes: $(plugin_geometry | tr '\n' ' ')" >&2
  fail "quedaron $(plugin_count) ventanas abiertas"
fi
echo "   ventanas restantes: 0 ✔"

echo "4) cerrar el panel de la prueba"
ensure_panel
# Dar tiempo a que el panel termine de abrirse antes de cerrarlo.
sleep 0.5
# El cierre se confirma en el estado del host. Se reintenta porque otro panel
# puede robar el foco justo antes o el host puede ignorar un cierre durante
# la animación de apertura.
deadline=$((SECONDS + 8))
while [ "$SECONDS" -lt "$deadline" ]; do
  [ "$(active_panel)" != "$PANEL" ] && break
  noctalia msg panel-close "$PANEL" >/dev/null 2>&1 || true
  sleep 0.3
done
if [ "$(active_panel)" = "$PANEL" ]; then
  fail "el panel no se cerró (sigue activo)"
fi
# onClose se ejecuta con el cierre; se fuerza el volcado antes de revisar.
if ! flush_log; then
  fail "no se pudo forzar el volcado del log; la revisión no sería completa"
fi
# Capturar las líneas que lleguen tarde (ruido ajeno o volcado diferido) antes
# de congelar la copia.
wait_log_quiet 3 15
stop_follower
# Con la copia volcada se comprueba que el cierre quedó registrado. El seguidor
# drena el fichero viejo antes de cambiar, así que la línea debe estar.
# El cierre debe haber quedado registrado en la copia (el seguidor drena el
# fichero viejo antes de cambiar, así que una rotación no lo oculta).
if ! grep -q "closing \"$PANEL\"" "$tmp/run.log"; then
  fail "el panel no se cerró (no aparece 'closing' en la copia del log)"
fi

echo "5) avisos y errores nuevos en el log durante toda la prueba"
LOG_CHECKED=1
review_log || fail "el log recibió avisos o errores durante la prueba"

echo "OK: la prueba de humo pasó"
