--!nonstrict
-- Nothing about this plugin is visible, so a person whose compositor has no
-- keybinding for it is told once how to make one.

boot()

contains("the hint was shown", notificationBodies(), "notify_hotkey_hint")
equals("shown once", #LayoutTest.notifications, 1)
equals("and remembered", LayoutTest.files["/data/hint-shown"], "1\n")
contains("the search looked for this plugin's IPC",
         commandMatching("grep -rlF"), "umedbazarov/layout-fix:service")

finish()
