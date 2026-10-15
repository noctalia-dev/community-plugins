#!/usr/bin/env python3
import sys
import os
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gdk, Gio, GLib, Pango

def format_size(bytes_size):
    if bytes_size < 1024:
        return f"{bytes_size} B"
    elif bytes_size < 1024 * 1024:
        return f"{bytes_size / 1024:.1f} KB"
    elif bytes_size < 1024 * 1024 * 1024:
        return f"{bytes_size / (1024 * 1024):.1f} MB"
    else:
        return f"{bytes_size / (1024 * 1024 * 1024):.2f} GB"

def run_quicklook(path):
    path = os.path.abspath(os.path.expanduser(path))
    if not os.path.exists(path):
        return

    app = Gtk.Application(application_id='dev.noctalia.dropover.quicklook')

    def on_activate(app):
        win = Gtk.ApplicationWindow(application=app)
        win.set_title(f"Quick Look — {os.path.basename(path)}")
        win.set_default_size(720, 520)

        # Styling
        css_provider = Gtk.CssProvider()
        css = """
        window {
            background-color: rgba(24, 24, 27, 0.95);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 16px;
        }
        .header-bar {
            padding: 10px 16px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
        }
        .title-text {
            color: #f4f4f5;
            font-size: 14px;
            font-weight: bold;
        }
        .info-text {
            color: #a1a1aa;
            font-size: 12px;
        }
        .code-box {
            font-family: monospace;
            font-size: 12px;
            background-color: #121214;
            color: #e4e4e7;
            padding: 12px;
            border-radius: 8px;
        }
        """
        css_provider.load_from_data(css.encode('utf-8'))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

        # Header
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        header.set_css_classes(["header-bar"])

        title_lbl = Gtk.Label(label=os.path.basename(path))
        title_lbl.set_css_classes(["title-text"])
        title_lbl.set_ellipsize(Pango.EllipsizeMode.END)
        title_lbl.set_hexpand(True)
        title_lbl.set_halign(Gtk.Align.START)
        header.append(title_lbl)

        size_str = format_size(os.path.getsize(path)) if os.path.isfile(path) else "文件夹"
        info_lbl = Gtk.Label(label=size_str)
        info_lbl.set_css_classes(["info-text"])
        header.append(info_lbl)

        close_btn = Gtk.Button.new_from_icon_name("window-close-symbolic")
        close_btn.connect("clicked", lambda b: app.quit())
        header.append(close_btn)

        main_box.append(header)

        # Content view
        _, ext = os.path.splitext(path)
        ext = ext.lower()
        is_image = ext in [".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".bmp"]

        if is_image:
            picture = Gtk.Picture.new_for_filename(path)
            picture.set_can_shrink(True)
            picture.set_content_fit(Gtk.ContentFit.CONTAIN)
            picture.set_hexpand(True)
            picture.set_vexpand(True)
            picture.set_margin_top(12)
            picture.set_margin_bottom(12)
            picture.set_margin_start(12)
            picture.set_margin_end(12)
            main_box.append(picture)
        else:
            # Text / code preview
            scrolled = Gtk.ScrolledWindow()
            scrolled.set_hexpand(True)
            scrolled.set_vexpand(True)
            scrolled.set_margin_top(10)
            scrolled.set_margin_bottom(10)
            scrolled.set_margin_start(10)
            scrolled.set_margin_end(10)

            text_view = Gtk.TextView()
            text_view.set_editable(False)
            text_view.set_monospace(True)
            text_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
            text_view.set_css_classes(["code-box"])

            content = ""
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read(20000) # Read up to 20KB for fast preview
            except Exception as e:
                content = f"无法预览文件内容: {e}"

            buf = text_view.get_buffer()
            buf.set_text(content)
            scrolled.set_child(text_view)
            main_box.append(scrolled)

        win.set_child(main_box)

        # Escape or Space to quit
        key_ctrl = Gtk.EventControllerKey.new()
        def on_key_pressed(ctrl, keyval, keycode, state):
            if keyval in [Gdk.KEY_Escape, Gdk.KEY_space, Gdk.KEY_q]:
                app.quit()
                return True
            return False
        key_ctrl.connect("key-pressed", on_key_pressed)
        win.add_controller(key_ctrl)

        win.present()

    app.connect('activate', on_activate)
    app.run(None)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        run_quicklook(sys.argv[1])
