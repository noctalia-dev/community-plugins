# Stasis (plugin local de Noctalia v5)

Widget de barra para **Noctalia Shell v5** que muestra el estado del gestor de
inactividad [Stasis](https://github.com/) mediante `stasis info --json`.

## Qué hace

Cada `interval` segundos (2 s por defecto) ejecuta `stasis info --json` de forma
asíncrona y traduce el campo `class` a un glifo. El color del glifo es el **color
de icono por defecto de Noctalia** (respeta el `icon_color` configurado para el
widget). El tooltip es el texto completo que ya devuelve Stasis.

| `class`                  | Glifo por defecto |
| ------------------------ | ----------------- |
| `active` / `idle_active` | `coffee`          |
| `idle_waiting`           | `hourglass`       |
| `manually_inhibited`     | `hand-stop`       |
| `idle_inhibited`         | `player-pause`    |
| `not_running`            | `moon`            |
| desconocido              | `question-mark`   |

Los glifos son **Tabler icons** (no Nerd Font), configurables desde
**Ajustes → Plugins → Stasis** o con el botón central del propio widget.

## Gestos

- **Clic derecho**: `exec stasis toggle-inhibit` (pausar / reanudar Stasis).
- **Clic central**: abre los ajustes del widget (comportamiento por defecto).
- El resto de gestos se pueden asignar en Ajustes → Barra → el widget.

## Ajustes

- `interval`: segundos entre llamadas a `stasis info --json` (1–60).
- `show_tooltip`: mostrar u ocultar el tooltip.
- `glyph_active`, `glyph_idle_waiting`, `glyph_manually_inhibited`,
  `glyph_idle_inhibited`, `glyph_not_running`, `glyph_unknown`.

## Estructura

```
stasis/
├── plugin.toml          # manifiesto: id rober/stasis, entrada [[widget]]
├── stasis.luau          # script del widget (Luau)
├── translations/en.json
└── translations/es.json
```

## Instalación en local

El plugin vive en `~/.local/share/noctalia/plugins/stasis/` y se detecta como
fuente **local**. Para habilitarlo:

```sh
noctalia msg plugins enable rober/stasis
```

Después, añade el widget a una barra desde **Ajustes → Barra**, o a mano en
`~/.local/state/noctalia/settings.toml`:

```toml
[bar.default]
end = [ ..., "stasis", ... ]

[widget.stasis]
type = "rober/stasis:stasis"
```

