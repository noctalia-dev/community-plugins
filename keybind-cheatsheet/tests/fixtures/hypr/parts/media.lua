-- 3. Media
Hyprland.config.bind(", XF86AudioMute", mute, { desc = "Mute" })
-- 4. Volume
-- A `--` inside the command string is not a comment: the description after it
-- must still be read, so this bind lands in "Volume", not "Other".
Hyprland.config.bind(", XF86AudioRaiseVolume", exec("wpctl set-volume --limit 1.0 @DEFAULT_AUDIO_SINK@ 5%+"), { description = "Volume up" })
