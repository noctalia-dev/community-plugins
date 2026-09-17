local testlib = require("./testlib")

require("./config_test")
require("./status_icon_test")
require("./system_target_test")
require("./system_target_check_test")
require("./closure_diff_test")
require("./nix_test")
require("./service_generation_test")
require("./service_closure_diff_test")
require("./service_flake_update_test")
require("./service_system_target_test")

testlib.run()
