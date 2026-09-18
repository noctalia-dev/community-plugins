#!/usr/bin/env python3
"""Open the desktop portal's image/import picker and print the selected path."""

import os
import sys
from urllib.parse import unquote, urlparse

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402


def main() -> int:
    import_mode = len(sys.argv) > 1 and sys.argv[1] == "import"
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    sender = bus.get_unique_name().lstrip(":").replace(".", "_")
    token = f"noctalia_reading_list_{os.getpid()}"
    request_path = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
    loop = GLib.MainLoop()
    result = {"path": "", "response": 1}

    def on_response(_connection, _sender, _path, _interface, _signal, parameters):
        response, values = parameters.unpack()
        result["response"] = response
        uris = values.get("uris", [])
        if response == 0 and uris:
            parsed = urlparse(uris[0])
            if parsed.scheme == "file":
                result["path"] = unquote(parsed.path)
        loop.quit()

    subscription = bus.signal_subscribe(
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        request_path,
        None,
        Gio.DBusSignalFlags.NONE,
        on_response,
    )

    if import_mode:
        title = "Import a reading list"
        filters = [
            ("Reading list files", [(0, "*.json"), (0, "*.md"), (0, "*.html"),
                                     (0, "*.htm"), (0, "*.txt"), (0, "*.csv")]),
            ("All files", [(0, "*")]),
        ]
    else:
        title = "Choose an image"
        filters = [(
            "Images", [
                (0, "*.png"),
                (0, "*.jpg"),
                (0, "*.jpeg"),
                (0, "*.webp"),
                (0, "*.gif"),
                (0, "*.svg"),
                (0, "*.bmp"),
                (0, "*.ico"),
            ],
        )]
    options = {
        "handle_token": GLib.Variant("s", token),
        "multiple": GLib.Variant("b", False),
        "modal": GLib.Variant("b", True),
        "filters": GLib.Variant("a(sa(us))", filters),
    }

    try:
        bus.call_sync(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.FileChooser",
            "OpenFile",
            GLib.Variant("(ssa{sv})", ("", title, options)),
            GLib.VariantType("(o)"),
            Gio.DBusCallFlags.NONE,
            10_000,
            None,
        )
        loop.run()
    except GLib.Error as error:
        print(f"Image picker failed: {error.message}", file=sys.stderr)
        return 2
    finally:
        bus.signal_unsubscribe(subscription)

    if result["path"]:
        print(result["path"])
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
