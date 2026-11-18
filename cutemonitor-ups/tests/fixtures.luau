--!nonstrict
-- Command outputs for the parser tests, with whitespace written out as escapes.
--
-- real_*  : captured verbatim from pwrstat 1.4.2 on a CP1500PFCLCDa (2026-10-11/12).
-- synth_* : built only from row formats and words found in the pwrstat 1.4.2
--           binary, for states no real capture exists for.

local function text(lines: { string }): string
  return table.concat(lines, "\n") .. "\n"
end

-- A -status report from { label, value } rows, padding labels with dots to
-- pwrstat's 29-column field.
local function status(properties, current): string
  local function rows(out, list)
    for _, row in list do
      table.insert(out, "\t\t" .. row[1] .. string.rep(".", 29 - #row[1]) .. " " .. row[2])
    end
  end
  local out = { "", "The UPS information shows as following:", "", "\tProperties:" }
  rows(out, properties)
  table.insert(out, "")
  table.insert(out, "\tCurrent UPS status:")
  rows(out, current)
  table.insert(out, "")
  return text(out)
end

local CP1500 = {
  { "Model Name", "CP1500PFCLCDa" },
  { "Firmware Number", "CR01802H1711" },
  { "Rating Voltage", "120 V" },
  { "Rating Power", "1000 Watt(1500 VA)" },
}

return {
  real_status_idle = text({
    "",
    "The UPS information shows as following:",
    "",
    "\tProperties:",
    "\t\tModel Name................... CP1500PFCLCDa",
    "\t\tFirmware Number.............. CR01802H1711",
    "\t\tRating Voltage............... 120 V",
    "\t\tRating Power................. 1000 Watt(1500 VA)",
    "",
    "\tCurrent UPS status:",
    "\t\tState........................ Normal",
    "\t\tPower Supply by.............. Utility Power",
    "\t\tUtility Voltage.............. 119 V",
    "\t\tOutput Voltage............... 119 V",
    "\t\tBattery Capacity............. 100 %",
    "\t\tRemaining Runtime............ 190 min.",
    "\t\tLoad......................... 0 Watt(0 %)",
    "\t\tLine Interaction............. None",
    "\t\tTest Result.................. Passed at 2026/10/05 08:22:32",
    "\t\tLast Power Event............. Over Voltage at 2026/10/11 20:32:49 for 3 sec.",
    "",
  }),

  real_status_loaded = text({
    "",
    "The UPS information shows as following:",
    "",
    "\tProperties:",
    "\t\tModel Name................... CP1500PFCLCDa",
    "\t\tFirmware Number.............. CR01802H1711",
    "\t\tRating Voltage............... 120 V",
    "\t\tRating Power................. 1000 Watt(1500 VA)",
    "",
    "\tCurrent UPS status:",
    "\t\tState........................ Normal",
    "\t\tPower Supply by.............. Utility Power",
    "\t\tUtility Voltage.............. 112 V",
    "\t\tOutput Voltage............... 112 V",
    "\t\tBattery Capacity............. 100 %",
    "\t\tRemaining Runtime............ 37 min.",
    "\t\tLoad......................... 210 Watt(21 %)",
    "\t\tLine Interaction............. None",
    "\t\tTest Result.................. Passed at 2026/10/05 08:22:32",
    "\t\tLast Power Event............. Over Voltage at 2026/10/11 20:32:49 for 3 sec.",
    "",
  }),

  real_config = text({
    "",
    "Daemon Configuration:",
    "",
    "Alarm .............................................. On",
    "Hibernate .......................................... Off",
    "Cloud .............................................. Off",
    "",
    "Action for Power Failure:",
    "",
    "\tDelay time since Power failure ............. 60 sec.",
    "\tRun script command ......................... On",
    "\tPath of script command ..................... /etc/powerpanel/pwrstatd-powerfail.sh",
    "\tDuration of command running ................ 0 sec.",
    "\tEnable shutdown system ..................... On",
    "",
    "Action for Battery Low:",
    "",
    "\tRemaining runtime threshold ................ 300 sec.",
    "\tBattery capacity threshold ................. 35 %.",
    "\tRun script command ......................... On",
    "\tPath of command ............................ /etc/powerpanel/pwrstatd-lowbatt.sh",
    "\tDuration of command running ................ 0 sec.",
    "\tEnable shutdown system ..................... On",
    "",
    "",
  }),

  synth_on_battery = status(CP1500, {
    { "State", "Power Failure" },
    { "Power Supply by", "Battery Power" },
    { "Utility Voltage", "0 V" },
    { "Output Voltage", "120 V" },
    { "Battery Capacity", "87 %" },
    { "Remaining Runtime", "38 min." },
    { "Load", "180 Watt(18 %)" },
    { "Line Interaction", "None" },
    { "Test Result", "Passed at 2026/10/05 08:22:32" },
    { "Last Power Event", "Over Voltage at 2026/10/11 20:32:49 for 3 sec." },
  }),

  synth_low_battery = status(CP1500, {
    { "State", "Low Battery" },
    { "Power Supply by", "Battery Power" },
    { "Utility Voltage", "0 V" },
    { "Output Voltage", "120 V" },
    { "Battery Capacity", "31 %" },
    { "Remaining Runtime", "4 min." },
    { "Load", "180 Watt(18 %)" },
    { "Line Interaction", "None" },
  }),

  synth_lost_comm = status(CP1500, {
    { "State", "Lost Communication" },
  }),

  -- Alternate row formats from the binary: Watt-only rating, %-only load,
  -- frequency rows, Boost, and the misspelled test result.
  synth_other_model = status({
    { "Model Name", "OR1500PFCRT2U" },
    { "Rating Voltage", "120 V" },
    { "Rating Power", "1000 Watt" },
  }, {
    { "State", "Normal" },
    { "Power Supply by", "Utility Power" },
    { "Utility Voltage", "104 V" },
    { "Output Voltage", "120 V" },
    { "Utility Frequency", "60.0 Hz" },
    { "Output Frequency", "59.9 Hz" },
    { "Battery Capacity", "100 %" },
    { "Remaining Runtime", "52 min." },
    { "Load", "18 %" },
    { "Line Interaction", "Boost" },
    { "Test Result", "Low Battert at 2026/10/05 08:22:32" },
    { "Last Power Event", "Under Voltage at 2026/10/09 00:13:18 for 2 min" },
  }),

  -- Rating order from the PowerPanel for Linux 1.4.1 manual's example.
  synth_older_rating = status({
    { "Model Name", "UPS CP585" },
    { "Rating Voltage", "120 V" },
    { "Rating Power", "515 VA (335 Watt)" },
  }, {
    { "State", "Normal" },
  }),

  error_daemon = "Daemon service is not found.\n",
  error_socket = "Create socket fail.\n",
  error_empty = "",
  error_garbage = "something unexpected\nsecond line\n",
}
