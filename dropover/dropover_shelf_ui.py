#!/usr/bin/env python3
import sys
import os
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gdk, Gio, GLib, Pango

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dropover_core

def format_size(bytes_size):
    if bytes_size < 1024:
        return f"{bytes_size} B"
    elif bytes_size < 1024 * 1024:
        return f"{bytes_size / 1024:.1f} KB"
    elif bytes_size < 1024 * 1024 * 1024:
        return f"{bytes_size / (1024 * 1024):.1f} MB"
    else:
        return f"{bytes_size / (1024 * 1024 * 1024):.2f} GB"

def get_glyph_name(path, is_dir):
    if is_dir:
        return "folder-symbolic"
    _, ext = os.path.splitext(path)
    ext = ext.lower().lstrip(".")
    if ext in ["png", "jpg", "jpeg", "webp", "gif", "svg", "bmp"]:
        return "image-x-generic-symbolic"
    elif ext in ["mp4", "mkv", "webm", "avi", "mov"]:
        return "video-x-generic-symbolic"
    elif ext in ["mp3", "flac", "wav", "ogg", "m4a"]:
        return "audio-x-generic-symbolic"
    elif ext in ["zip", "tar", "gz", "7z", "rar", "zst"]:
        return "package-x-generic-symbolic"
    elif ext in ["py", "lua", "luau", "sh", "js", "ts", "rs", "c", "cpp", "kdl", "toml", "json"]:
        return "text-x-script-symbolic"
    elif ext in ["pdf", "txt", "md", "doc", "docx", "csv"]:
        return "x-office-document-symbolic"
    else:
        return "text-x-generic-symbolic"

def run_shelf():
    items = dropover_core.load_shelf()
    if not items:
        os.system("noctalia msg notification-show 'Dropover' '暂存架当前是空的，暂无可拖出文件' 2>/dev/null || true")
        return

    app = Gtk.Application(application_id='dev.noctalia.dropover.shelf')

    def on_activate(app):
        win = Gtk.ApplicationWindow(application=app)
        win.set_title("Dropover 随身暂存架")
        win.set_default_size(360, 420)

        # Material 3 Styling
        css_provider = Gtk.CssProvider()
        css = """
        window {
            background-color: rgba(24, 24, 28, 0.95);
            border-radius: 22px;
            border: 1px solid rgba(255, 177, 195, 0.4);
            box-shadow: 0 18px 40px rgba(0, 0, 0, 0.6);
        }
        .header-bar {
            padding: 12px 16px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
        }
        .title-text {
            color: #ffffff;
            font-size: 14px;
            font-weight: bold;
        }
        .drag-all-pill {
            background: rgba(255, 177, 195, 0.18);
            color: #ffb1c3;
            border-radius: 14px;
            padding: 4px 12px;
            font-size: 11px;
            font-weight: bold;
            border: 1px solid rgba(255, 177, 195, 0.4);
            transition: all 120ms ease-out;
        }
        .drag-all-pill:hover {
            background: rgba(255, 177, 195, 0.35);
            color: #ffffff;
        }
        .file-card {
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid rgba(255, 255, 255, 0.07);
            border-radius: 14px;
            padding: 10px 12px;
            margin: 4px 8px;
            transition: all 120ms ease-out;
        }
        .file-card:hover {
            background: rgba(255, 177, 195, 0.12);
            border-color: rgba(255, 177, 195, 0.45);
        }
        .file-title {
            color: #f4f4f5;
            font-size: 13px;
            font-weight: 600;
        }
        .file-meta {
            color: #a1a1aa;
            font-size: 11px;
        }
        .drag-badge {
            background: rgba(255, 177, 195, 0.15);
            color: #ffb1c3;
            font-size: 10px;
            font-weight: bold;
            padding: 2px 6px;
            border-radius: 6px;
        }
        .card-thumb {
            border-radius: 8px;
        }
        """
        css_provider.load_from_data(css.encode('utf-8'))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)

        # Header
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        header.set_css_classes(["header-bar"])

        title_lbl = Gtk.Label(label=f"📥 Dropover ({len(items)} 项)")
        title_lbl.set_css_classes(["title-text"])
        title_lbl.set_halign(Gtk.Align.START)
        title_lbl.set_hexpand(True)
        header.append(title_lbl)

        # "拖出全部" Pill
        drag_all_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        drag_all_box.set_css_classes(["drag-all-pill"])
        drag_all_icon = Gtk.Image.new_from_icon_name("view-paged-symbolic")
        drag_all_icon.set_pixel_size(14)
        drag_all_lbl = Gtk.Label(label="拖出全部")
        drag_all_box.append(drag_all_icon)
        drag_all_box.append(drag_all_lbl)

        # Attach DragSource to "拖出全部"
        all_files = [Gio.File.new_for_path(p) for p in items if os.path.exists(p)]
        if all_files:
            drag_all_source = Gtk.DragSource.new()
            drag_all_source.set_actions(Gdk.DragAction.COPY)
            drag_all_source.set_content(Gdk.ContentProvider.new_for_value(Gdk.FileList.new_from_list(all_files)))
            
            def on_drag_all_end(src, drag, delete_data):
                # Dropped successfully, clear shelf
                dropover_core.clear_shelf()
                os.system("noctalia msg notification-show 'Dropover' '已全部移出到目标窗口' 2>/dev/null || true")
                app.quit()

            drag_all_source.connect("drag-end", on_drag_all_end)
            drag_all_box.add_controller(drag_all_source)

        header.append(drag_all_box)

        close_btn = Gtk.Button.new_from_icon_name("window-close-symbolic")
        close_btn.set_css_classes(["close-icon-btn"])
        close_btn.connect("clicked", lambda b: app.quit())
        header.append(close_btn)

        main_box.append(header)

        # Subtitle hint
        hint_lbl = Gtk.Label(label="直接按住卡片拖入目标软件 • 单击卡片直接复制")
        hint_lbl.set_css_classes(["file-meta"])
        hint_lbl.set_margin_top(4)
        hint_lbl.set_margin_bottom(2)
        main_box.append(hint_lbl)

        # Scrolled card list
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_hexpand(True)
        scrolled.set_vexpand(True)
        scrolled.set_margin_start(8)
        scrolled.set_margin_end(8)
        scrolled.set_margin_bottom(8)

        card_list_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)

        for p in items:
            exists = os.path.exists(p)
            name = os.path.basename(p)
            is_dir = os.path.isdir(p) if exists else False
            size_str = format_size(os.path.getsize(p)) if (exists and not is_dir) else ("文件夹" if is_dir else "已丢失")
            
            card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            card.set_css_classes(["file-card"])

            # Left: Thumbnail or Glyph
            _, ext = os.path.splitext(p)
            is_image = ext.lower() in [".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".bmp"]
            if is_image and exists:
                pic = Gtk.Picture.new_for_filename(p)
                pic.set_can_shrink(True)
                pic.set_content_fit(Gtk.ContentFit.COVER)
                pic.set_size_request(46, 46)
                pic.set_css_classes(["card-thumb"])
                card.append(pic)
            else:
                icon_box = Gtk.Box()
                icon_box.set_size_request(46, 46)
                icon_box.set_valign(Gtk.Align.CENTER)
                icon_box.set_halign(Gtk.Align.CENTER)
                icon = Gtk.Image.new_from_icon_name(get_glyph_name(p, is_dir))
                icon.set_pixel_size(28)
                icon_box.append(icon)
                card.append(icon_box)

            # Center: Title & meta
            info_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            info_col.set_hexpand(True)
            info_col.set_valign(Gtk.Align.CENTER)

            name_lbl = Gtk.Label(label=name)
            name_lbl.set_css_classes(["file-title"])
            name_lbl.set_halign(Gtk.Align.START)
            name_lbl.set_ellipsize(Pango.EllipsizeMode.END)
            name_lbl.set_max_width_chars(22)
            info_col.append(name_lbl)

            meta_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            size_lbl = Gtk.Label(label=size_str)
            size_lbl.set_css_classes(["file-meta"])
            meta_row.append(size_lbl)

            ext_tag = ext.upper().lstrip(".") if ext else ("DIR" if is_dir else "FILE")
            tag_lbl = Gtk.Label(label=ext_tag)
            tag_lbl.set_css_classes(["drag-badge"])
            meta_row.append(tag_lbl)

            info_col.append(meta_row)
            card.append(info_col)

            # Right: Drag handle indicator
            drag_icon = Gtk.Image.new_from_icon_name("open-menu-symbolic")
            drag_icon.set_pixel_size(16)
            drag_icon.set_css_classes(["file-meta"])
            drag_icon.set_valign(Gtk.Align.CENTER)
            card.append(drag_icon)

            # --- Controller 1: DragSource (Direct Dragging Out!) ---
            if exists:
                drag_source = Gtk.DragSource.new()
                drag_source.set_actions(Gdk.DragAction.COPY)
                gfile = Gio.File.new_for_path(p)
                fl = Gdk.FileList.new_from_list([gfile])
                drag_source.set_content(Gdk.ContentProvider.new_for_value(fl))

                target_path = p
                def make_drag_end_callback(file_to_remove):
                    def on_item_drag_end(src, drag, delete_data):
                        dropover_core.remove_file(file_to_remove)
                        # Check remaining items
                        remaining = dropover_core.load_shelf()
                        if not remaining:
                            app.quit()
                    return on_item_drag_end

                drag_source.connect("drag-end", make_drag_end_callback(target_path))
                card.add_controller(drag_source)

            # --- Controller 2: Click to Copy ---
            click_gesture = Gtk.GestureClick.new()
            target_path_click = p
            def make_click_callback(file_to_copy, file_name):
                def on_card_clicked(gesture, n_press, x, y):
                    dropover_core.copy_to_clipboard([file_to_copy])
                    os.system(f"noctalia msg notification-show 'Dropover' '已复制「{file_name}」，可在目标窗口按 Ctrl+V 粘贴' 2>/dev/null || true")
                    app.quit()
                return on_card_clicked

            click_gesture.connect("released", make_click_callback(target_path_click, name))
            card.add_controller(click_gesture)

            card_list_box.append(card)

        scrolled.set_child(card_list_box)
        main_box.append(scrolled)
        win.set_child(main_box)

        # Close on Escape or Q
        key_ctrl = Gtk.EventControllerKey.new()
        key_ctrl.connect("key-pressed", lambda c, k, code, s: app.quit() if k in [Gdk.KEY_Escape, Gdk.KEY_q] else False)
        win.add_controller(key_ctrl)

        win.present()

    app.connect('activate', on_activate)
    app.run(None)

if __name__ == "__main__":
    run_shelf()
