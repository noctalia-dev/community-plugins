--!nonstrict
-- The marker survives restarts: the hint is a one-time thing, not a nag.

LayoutTest.files["/data/hint-shown"] = "1\n"
boot()

equals("no hint on the next start", #LayoutTest.notifications, 0)
equals("and no config search either", commandMatching("grep -rlF"), nil)

finish()
