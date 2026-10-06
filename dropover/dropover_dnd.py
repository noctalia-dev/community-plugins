#!/usr/bin/env python3
import sys
import os
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gdk, Gio, GLib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dropover_core

def run_drop_window():
    app = Gtk.Application(application_id='dev.noctalia.dropover.drop')

    def on_activate(app):
        win = Gtk.ApplicationWindow(application=app)
        win.set_title("Dropover 磁吸暂存区")
        win.set_default_size(360, 220)

        # Material 3 Expressive frosted style
        css_provider = Gtk.CssProvider()
        css = """
        window {
            background-color: rgba(26, 26, 30, 0.94);
            border-radius: 24px;
            border: 2px dashed rgba(255, 177, 195, 0.65);
            box-shadow: 0 16px 32px rgba(0, 0, 0, 0.5);
        }
        window:hover {
            border: 2px dashed #ffb1c3;
            background-color: rgba(36, 34, 40, 0.97);
        }
        .main-icon {
            color: #ffb1c3;
            margin-bottom: 8px;
        }
        .drop-title {
            color: #f4f4f5;
            font-size: 16px;
            font-weight: bold;
        }
        .drop-hint {
            color: #a1a1aa;
            font-size: 12px;
        }
        """
        css_provider.load_from_data(css.encode('utf-8'))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        box.set_margin_top(24)
        box.set_margin_bottom(24)
        box.set_margin_start(24)
        box.set_margin_end(24)

        icon = Gtk.Image.new_from_icon_name("folder-download-symbolic")
        icon.set_pixel_size(56)
        icon.set_css_classes(["main-icon"])
        box.append(icon)

        label = Gtk.Label(label="松开鼠标即可存入")
        label.set_css_classes(["drop-title"])
        box.append(label)

        sub_label = Gtk.Label(label="Dropover 就地磁吸  •  按 Esc 取消")
        sub_label.set_css_classes(["drop-hint"])
        box.append(sub_label)

        win.set_child(box)

        drop = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)

        def on_drop(target, file_list, x, y):
            if file_list:
                paths = []
                gfiles = file_list.get_files()
                for gf in gfiles:
                    p = gf.get_path()
                    if p:
                        paths.append(p)
                added = dropover_core.add_files(paths)
                os.system(f"noctalia msg notification-show 'Dropover' '已磁吸暂存 {added} 个文件' 2>/dev/null || true")
                app.quit()
                return True
            return False

        drop.connect("drop", on_drop)
        win.add_controller(drop)

        # Close on Escape or click
        key_ctrl = Gtk.EventControllerKey.new()
        key_ctrl.connect("key-pressed", lambda c, k, code, s: app.quit() if k == Gdk.KEY_Escape else False)
        win.add_controller(key_ctrl)

        win.present()

    app.connect('activate', on_activate)
    app.run(None)

def run_drag_window(file_path):
    if not os.path.exists(file_path):
        return
    app = Gtk.Application(application_id='dev.noctalia.dropover.drag')

    def on_activate(app):
        win = Gtk.ApplicationWindow(application=app)
        win.set_title("Dropover 拖出")
        win.set_default_size(260, 64)

        css_provider = Gtk.CssProvider()
        css = """
        window {
            background-color: rgba(30, 28, 34, 0.95);
            border-radius: 16px;
            border: 1px solid rgba(255, 177, 195, 0.5);
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.4);
        }
        .drag-label {
            color: #ffffff;
            font-size: 13px;
            font-weight: 600;
        }
        """
        css_provider.load_from_data(css.encode('utf-8'))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        box.set_valign(Gtk.Align.CENTER)
        box.set_margin_top(10)
        box.set_margin_bottom(10)
        box.set_margin_start(16)
        box.set_margin_end(16)

        icon_name = "image-x-generic" if file_path.lower().endswith(('.png', '.jpg', '.jpeg', '.webp')) else "text-x-generic"
        icon = Gtk.Image.new_from_icon_name(icon_name)
        icon.set_pixel_size(28)
        box.append(icon)

        name_label = Gtk.Label(label=os.path.basename(file_path))
        name_label.set_css_classes(["drag-label"])
        name_label.set_ellipsize(3)
        name_label.set_max_width_chars(18)
        box.append(name_label)

        win.set_child(box)

        drag_source = Gtk.DragSource.new()
        drag_source.set_actions(Gdk.DragAction.COPY)
        gfile = Gio.File.new_for_path(file_path)
        fl = Gdk.FileList.new_from_list([gfile])
        content = Gdk.ContentProvider.new_for_value(fl)
        drag_source.set_content(content)

        drag_source.connect("drag-end", lambda *a: app.quit())
        drag_source.connect("drag-cancel", lambda *a: app.quit())
        win.add_controller(drag_source)

        key_ctrl = Gtk.EventControllerKey.new()
        key_ctrl.connect("key-pressed", lambda c, k, code, s: app.quit() if k == Gdk.KEY_Escape else False)
        win.add_controller(key_ctrl)

        win.present()

    app.connect('activate', on_activate)
    app.run(None)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "drag" and len(sys.argv) > 2:
        run_drag_window(sys.argv[2])
    else:
        run_drop_window()
