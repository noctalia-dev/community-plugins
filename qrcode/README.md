# QR Code encoder

Transform any text or URL into a QR code completely offline. Then scan or copy the code.

## Plugin

| Field | Value |
| --- | --- |
| ID | `yocraft/qrcode` |
| Entries | Bar widget: `widget`; panel: `panel` |

## Requirements

Install `qrencode` on `PATH`.

## Usage

Open the panel from the bar widget or with this command:
```sh
noctalia msg panel-toggle yocraft/qrcode:panel
```

Enter your text or URL and click on Generate or press enter to generate the QR code, then scan it from the panel or copy it by clicking on it.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `titlebar` | `bool` | `true` | Show titlebar, panel name and buttons like settings and close. |
| `generate_button` | `bool` | `true` | Show Generate button, disable will submit on enter. |
| `close_on_copy` | `bool` | `false` | Close the panel when copying the QR code. |
| `notify` | `select` | `minimal` | Controls the notifications, minimal only notifies when Close on Copy is used. |
| `keep_on_close` | `bool` | `false` | Keep the input, QR Code, status etc when closing the panel. |
| `size` | `int` | `8` | Specify module size in dots (pixels). |
| `correction_level` | `select` | `M` | Specify error correction level. |
| `glyph` | `glyph` | `qrcode` | Bar widget icon glyph name. |
| `custom_image` | `image` | `""` | Path to a custom image; leave empty to use the icon glyph. |

## Notes

The plugin runs entirely locally and does not require network access.
The plugin does not store anyting in files when the panel is closed, except when `keep_on_close` option is enabled.
