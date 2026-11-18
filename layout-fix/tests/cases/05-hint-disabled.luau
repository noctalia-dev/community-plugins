--!nonstrict
-- Turned off in settings: no hint, and no marker either — turning it back on
-- should still be able to show it.

LayoutTest.config.hotkey_hint = false
boot()

equals("no hint", #LayoutTest.notifications, 0)
equals("nothing remembered", LayoutTest.files["/data/hint-shown"], nil)
equals("no config search", commandMatching("grep -rlF"), nil)

finish()
