# Ayet Köşesi

Ayet Köşesi is a Noctalia desktop widget that displays a daily verse from the public Akıl Kuran API.

## Plugin

- **ID:** `alitura1/ayet-kosesi`
- **Entry:** `ayet`
- **License:** MIT

## Requirements

- `curl` must be installed and available on `PATH`; it is used to refresh the Akıl Kuran logo.

## External dependencies

The plugin depends on the `curl` command.

## Usage

Add the `ayet` desktop widget from Noctalia's desktop widget settings.

The widget displays a daily verse, the selected translation author, and an Akıl Kuran logo.

Click **Akıl Kuran'da aç** to open the displayed verse on akilkuran.com.

## Translation selection

The plugin can use a local translation/meal ID.

Create:

`~/.config/ayet-kosesi/meal-id`

and put the numeric meal ID inside.

Example:

`14`

When no local ID is present, the API default translation is used.

## Network and storage

Verse data is requested from the public Akıl Kuran API:

`https://akilkuran.com/api/quran/surah/<surah>`

The Akıl Kuran logo is refreshed once per day and cached locally.

When the network is unavailable, the existing cached logo and cached verse remain available.

The plugin does not access user accounts, browser storage, cookies, Firebase credentials, or private Akıl Kuran source code.

The plugin does not download or execute remote code.

## Desktop widget

Entry ID:

`ayet`

No panel IPC command or launcher prefix is provided by this plugin.
