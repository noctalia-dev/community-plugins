--!nonstrict
-- Startup: the daemon is copied to a stable path, started when it is not
-- already running, and told which mode the settings ask for.

boot()

contains("daemon installed from the plugin dir", commandMatching("cp -f"), "/plugin/scripts/layout-fix")
contains("installed into the data dir", commandMatching("cp -f"), "/data/layout-fix")
check("it is made executable", commandMatching("chmod +x") ~= nil)
check("liveness probed", commandMatching("/data/layout-fix' status") ~= nil)
check("daemon launched detached", commandMatching("setsid") ~= nil)
contains("automatic mode is on by default", commandMatching("auto on"), "auto on")
equals("no error notifications", #LayoutTest.errors, 0)

finish()
