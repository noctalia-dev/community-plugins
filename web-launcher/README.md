# Web Launcher

Quickly open your favorite websites from the launcher. Favicons are downloaded automatically!

## Plugin

| Field | Value |
| --- | --- |
| ID | `yocraft/web-launcher` |
| Entries | Launcher provider: `web-launcher` |
| Launcher Prefix | `web` |

## Requirements

A browser.

## Usage

Open the Noctalia launcher and type `/web` to list all configurated websites.
Continue typing to filter by name, then activate a result to launch that website in your default browser.
You can customize the list and order of websites in settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `links` | `string_list` | `see below` | Websites list and order. |
| `notify` | `bool` | `false` | Toggle notification when launching website. |

Default links:
```
"GitHub|https://github.com",
"GitLab|https://gitlab.com",
"Codeberg|https://codeberg.org",
"Reddit|https://reddit.com",
"YouTube|https://youtube.com",
"Gmail|https://mail.google.com",
```
