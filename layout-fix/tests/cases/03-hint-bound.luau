--!nonstrict
-- Someone whose config already spawns the plugin's IPC has clearly found the
-- keybindings; telling them about it would be noise.

LayoutTest.respond("grep -rlF", "/home/user/.config/niri/config.kdl\n")
boot()

equals("no hint", #LayoutTest.notifications, 0)
equals("but the search is not repeated later", LayoutTest.files["/data/hint-shown"], "1\n")

finish()
