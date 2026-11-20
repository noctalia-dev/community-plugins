# Wallpaper Deck

A feature-packed native Noctalia wallpaper manager inspired by Magic: The Gathering cards. Combines fluid 3D spring coverflow animations with Material 3 dynamic color extraction, auto-apply desktop widget profiles, color-search filtering, custom theme creation, multi-monitor targeting, and built-in Wallhaven integration.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ishan0121/wallpaper-deck` |
| Version | `1.6.0` |
| License | `GPL-3.0` |
| Author | `Ishan0121` |
| Entries | Bar widget: `bar`; panel: `picker`; shortcut: `toggle`; service: `service` |
| Dependencies | `ffmpeg`, `matugen` *(optional: `swww`, `awww`)* |

---

## Key Features

- **Tiered 3D Coverflow Deck**: Smooth MTG-style layered card deck with spring physics, responsive card scaling, mouse wheel / trackpad gesture scrolling, and active card bobbing animation.
- **Desktop Widget Profiles**: Snapshot your live Noctalia desktop widget layout and bind it to specific wallpapers and monitor outputs. Supports auto-applying layouts on wallpaper change, multi-monitor scoped patching, quick-pick conflict resolution, and automatic safety backups.
- **Search by Color**: Filter local and favourite wallpapers by hue with an integrated color picker. Uses non-blocking batched async processing to match against extracted Material 3 palette roles (primary, secondary, tertiary, container, surface).
- **Chromatic Hue Spectrum**: Edge-to-edge interactive spectrum ribbon at the top of the deck; click any color band to jump directly to wallpapers matching that hue.
- **Dynamic Theming & Custom Palettes**:
  - Switch palette sources on the fly between **Wallpaper** (7 Material 3 scheme variants), **Built-In** (Noctalia, Dracula, Catppuccin, Nord, Gruvbox, etc.), **Community**, and **Custom**.
  - Built-in **Custom Theme Creator** modal: design, preview, and save Noctalia Format 2 JSON palettes directly to `~/.config/noctalia/palettes/` with auto-generated terminal color schemes.
  - Quick theme mode switcher (**Dark** / **Light** / **Auto**) right in the top header.
- **Wallhaven Integration**:
  - Browse and search millions of online wallpapers directly inside the deck.
  - Filter by category (**General**, **Anime**, **People**) via a dedicated popover modal.
  - Filter by purity (**SFW**, **Sketchy**, **NSFW** with API key).
  - Target specific resolutions (**At Least** or **Exact**) and aspect ratios (**16:9**, **21:9**, **32:9**, Portrait, etc.).
  - Sort by Date Added, Toplist, Hot, Views, Favorites, Relevance, or Random with Asc/Desc toggle.
  - Infinite scroll lazy-loading and configurable disk cache for hi-res previews.
- **Multi-Monitor Targeting & Custom Engines**:
  - Apply wallpapers to individual connected monitors or all displays simultaneously.
  - Use Noctalia's native wallpaper surface or custom wallpaper daemons (`swww`, `awww`, etc.) with `{path}` and `{output}` template substitution.
  - Execute optional post-apply shell hooks (e.g. `matugen image "{path}"`).
- **Live Preview & Inspection**:
  - Fullscreen live preview behind the cards that promotes to high-res on card settle.
  - Cycle background fit modes (**Cover**, **Contain**, **Stretch**).
  - Peek mode (`Space`) to hide all UI elements and inspect the full wallpaper.
  - Favourites management (`F`) and random shuffle (`R`).

---

## Requirements

Ensure `ffmpeg` and `matugen` are installed and available on your `PATH`:

- **`ffmpeg`**: Generates high-speed cached thumbnails for local and Wallhaven wallpapers.
- **`matugen`**: Extracts Material 3 dynamic color palettes from wallpapers.

### Optional Wallpaper Daemons

If `backend_mode` is set to `custom`, install your preferred wallpaper daemon:
- **`swww`**: `swww img "{path}" --transition-type grow --transition-fps 60`
- **`awww`**: `awww img "{path}"`

---

## Usage

### Opening the Wallpaper Picker

You can open the picker using the Noctalia IPC command, the bar widget, or a compositor shortcut:

```sh
noctalia msg panel-toggle ishan0121/wallpaper-deck:picker
```

#### Bar Widget

Add the `bar` widget to your Noctalia bar under **Settings** (`Mod+Shift+S`) -> **Bar** -> **Widgets**. Left-clicking the widget toggles the wallpaper picker.

#### Compositor Shortcuts

Bind the toggle command in your compositor config:

- **Hyprland** (`~/.config/hypr/hyprland.conf`):
  ```ini
  bind = $mainMod, W, exec, noctalia msg panel-toggle ishan0121/wallpaper-deck:picker
  ```
- **Niri** (`~/.config/niri/config.kdl`):
  ```kdl
  Mod+W { spawn "noctalia" "msg" "panel-toggle" "ishan0121/wallpaper-deck:picker"; }
  ```
- **Sway** (`~/.config/sway/config`):
  ```ini
  bindsym $mod+w exec noctalia msg panel-toggle ishan0121/wallpaper-deck:picker
  ```

---

### Desktop Widget Profiles

Wallpaper Deck allows you to snapshot your live Noctalia desktop widget layout and bind it to specific wallpapers and monitor outputs.

1. **Creating a Profile**:
   - Arrange your desktop widgets in Noctalia as desired.
   - Open Wallpaper Deck and select the target wallpaper.
   - Click **`Profiles`** in the top action bar, then click **`+ Add Profile`**.
   - Enter a profile name, choose the target monitor scope (**ALL** or a specific output connector), and choose whether to snapshot the live layout or link the selected wallpaper. You can also save the active color scheme with the profile.
2. **Auto-Apply Desktop Widgets**:
   - Toggle the **`Widgets`** button in the top bar. When ON (`✓`), applying a wallpaper automatically restores its linked desktop widget layout.
   - Layout updates are scoped to the selected monitor, leaving widgets on other displays untouched.
3. **Quick-Pick Selection**:
   - If multiple profiles are associated with the same wallpaper, a Quick-Pick popover appears when applying the wallpaper, letting you select which profile to apply or choose "Wallpaper Only".
4. **Safety Backup & Layout Updates**:
   - Every profile application creates an automatic backup (`_previous.json`). You can revert to the previous widget layout at any time using the **`Revert Safety Backup`** button in the Profiles modal.
   - You can update an existing profile's stored widgets to your live desktop layout with one click using the update icon in the Profiles list.

---

### Search by Color & Spectrum Jump

- **Color Search**: Click the palette icon (`Color`) next to the search input in the **Local** or **Favourites** tabs. Select any color using the color picker. The deck will asynchronously filter wallpapers whose Material 3 palette roles (primary, secondary, tertiary, container, or surface) match the target hue.
- **Spectrum Ribbon**: An interactive chromatic spectrum bar spans the top of the card deck. Click anywhere on the gradient to jump straight to that hue section of the deck.
- **Sorting Options**: Press `S` or click the sort pills to switch between **Name A-Z**, **Name Z-A**, **Colour** (chromatic hue order), **Newest**, and **Oldest**.

---

### Theming & Custom Palettes

- **Palette Source Dropdown**: Located in the top header, choose between:
  - **Wallpaper**: Material 3 schemes extracted directly from the wallpaper (`rainbow`, `tonal-spot`, `vibrant`, `expressive`, `fidelity`, `content`, `fruit-salad`).
  - **Built-In**: Noctalia standard palettes (Noctalia, Dracula, Nord, Catppuccin Mocha, Gruvbox Dark, etc.).
  - **Community**: Any community color palettes installed on your system.
  - **Custom**: User-created custom color schemes.
- **Custom Theme Creator**:
  - When **Custom** is selected, click the **`+`** button to open the Theme Creator modal.
  - Define custom hex colors for dark and light roles.
  - The modal automatically generates terminal colors (normal, bright, background, foreground, cursor, and selection).
  - Saved themes are stored in `~/.config/noctalia/palettes/<name>.json` in Noctalia Format 2 and can be applied or deleted directly from the picker.
- **Theme Mode**: Switch between **Dark** (`moon`), **Light** (`sun`), and **Auto** (`brightness-auto`) using the header pill buttons.

---

### Wallhaven Browser

- Switch to the **Wallhaven** tab to explore online wallpapers.
- **Search Bar**: Type any keyword and press `Enter` or click `Search`.
- **Category Modal**: Click the **`Categories`** button to toggle **General**, **Anime**, and **People** in a modal popover.
- **Purity Pills**: Toggle **SFW**, **Sketchy**, and **NSFW** (requires API key in settings).
- **Resolution & Aspect Ratio**: Filter by minimum or exact resolutions and standard aspect ratios (`16:9`, `21:9`, `32:9`, `Portrait`, etc.).
- **Hi-Res Preview (`P`)**: Preload high-resolution full-screen previews directly into the disk cache before applying.
- Wallpapers applied from Wallhaven are automatically saved to your download directory (`~/Pictures/WallHaven`) and seamlessly integrated into your local collection.

---

## Controls & Keybindings

| Key / Gesture | Action |
| --- | --- |
| `←` / `→` or `h` / `l` | Browse cards left / right |
| `Mouse Wheel` | Smoothly scroll through the card deck (hover over cards or deck container) |
| `↑` / `↓` or `j` / `k` or `u` / `d` | Jump 5 cards backward / forward |
| `Page_Up` / `Page_Down` | Jump 5 cards backward / forward |
| `Enter` / `Return` | Apply selected wallpaper (or execute Wallhaven search if search input is focused) |
| `Space` | Toggle Peek mode (temporarily hides cards and UI to inspect full wallpaper) |
| `V` | Cycle background preview fit mode (`cover` -> `contain` -> `stretch`) |
| `F` | Toggle favourite status on current wallpaper |
| `S` | Cycle sort mode (`Name A-Z` -> `Name Z-A` -> `Colour` -> `Newest` -> `Oldest`) |
| `R` | Jump to a random wallpaper |
| `P` | Toggle hi-res preview in Wallhaven mode (or Peek mode in Local/Favourites) |
| `M` | Toggle target monitor selection dropdown |
| `Tab` | Cycle source tab (`Local` -> `Favourites` -> `Wallhaven`) |
| `/` | Focus search filter bar |
| `Esc` | Close open modal/popover (Profiles, Theme Creator, Categories, Monitor menu, Peek) or close picker |
| `Left Click (Card)` | Focus flanking card, or apply wallpaper if already centered |
| `Right Click (Apply)` | Toggle target monitor selection dropdown |
| `Click (Spectrum Ribbon)` | Jump directly to that color position in the deck |

---

## Settings

Configure under Noctalia Settings (**Settings** -> **Plugins** -> **Wallpaper Deck**):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `wallpaper_dir` | `folder` | `~/Pictures/Wallpapers` | Primary directory scanned for wallpapers. |
| `extra_wallpaper_dir` | `folder` | `~/Pictures/WallHaven` | Secondary directory scanned for wallpapers. |
| `include_wallhaven_downloads` | `bool` | `true` | Automatically includes the Wallhaven download directory in the local deck. |
| `additional_wallpaper_dirs` | `string_list` | `[]` | List of extra directories to scan (add more using the '+' button in Settings). |
| `scan_subdirectories` | `bool` | `true` | Recursively search subdirectories inside wallpaper folders. |
| `backend_mode` | `select` | `native` | Wallpaper engine mode: `native` (Noctalia surface) or `custom`. |
| `custom_command` | `string` | `swww img "{path}" --transition-type grow --transition-fps 60` | Shell command executed when `backend_mode` is set to `custom`. Supports `{path}` and `{output}` placeholders. |
| `post_hook_command` | `string` | `""` | Optional shell hook executed after applying a wallpaper (e.g. `matugen image "{path}"`). |
| `animate_selected_card` | `bool` | `true` | Enables subtle floating bobbing animation on the active center card. |
| `preview_fit` | `select` | `cover` | How fullscreen background preview fits the panel (`cover`, `contain`, `stretch`). |
| `scale_compensation` | `select` | `auto` | Controls how monitor HiDPI scaling is applied to preview dimensions (`auto`, `scaled`, `unscaled`). |
| `panel_padding_offset` | `int` | `0` | Total horizontal/vertical inset subtracted for panel chrome and borders. |
| `wallhaven_api_key` | `string` | `""` | Optional Wallhaven API key (unlocks NSFW purity filters and personal collections). |
| `wallhaven_categories` | `string` | `"111"` | Wallhaven categories bitflag (`General`/`Anime`/`People`, e.g. `111`). |
| `wallhaven_purity` | `string` | `"100"` | Wallhaven purity bitflag (`SFW`/`Sketchy`/`NSFW`, e.g. `100` for SFW). |
| `wallhaven_sorting` | `string` | `"date_added"` | Default Wallhaven sort criterion (`date_added`, `toplist`, `hot`, `views`, `favorites`, `relevance`, `random`). |
| `wallhaven_order` | `string` | `"desc"` | Sort direction (`desc` or `asc`). |
| `wallhaven_hires_preview` | `bool` | `false` | Preloads full-resolution backgrounds when browsing Wallhaven cards. |
| `wallhaven_cache_limit_mb` | `int` | `300` | Disk cache quota in megabytes for online previews before auto-pruning (50 to 2000 MB). |
| `wallhaven_download_dir` | `folder` | `~/Pictures/WallHaven` | Directory where downloaded Wallhaven wallpapers are stored. |

---

## IPC Interface

Trigger panel and service actions via Noctalia's IPC interface from the command line, scripts, or window manager bindings:

```sh
# Toggle picker panel
noctalia msg panel-toggle ishan0121/wallpaper-deck:picker

# Open picker panel
noctalia msg panel-open ishan0121/wallpaper-deck:picker

# Close picker panel
noctalia msg panel-close ishan0121/wallpaper-deck:picker

# Trigger full wallpaper rescanning
noctalia msg plugin ishan0121/wallpaper-deck:service all rescan
```
