--!nonstrict
-- upsc outputs for the NUT parser tests.
--
-- real_ddl_* : variable lines verbatim from NUT's device-dump library for the
--              CP1500PFCLCD (usbhid-ups 2.7.4; the DDL's comment lines omitted).
-- real_error_* : captured on this machine with no NUT server running (2026-10-11).
-- synth_*    : built only from variables in NUT 2.8.5's cps-hid driver and
--              status flags from NUT's documentation.

local function text(lines: { string }): string
  return table.concat(lines, "\n") .. "\n"
end

return {
  real_ddl_01 = text({
    "battery.charge: 100",
    "battery.charge.low: 10",
    "battery.charge.warning: 20",
    "battery.mfr.date: CPS",
    "battery.runtime: 1530",
    "battery.runtime.low: 300",
    "battery.type: PbAcid",
    "battery.voltage: 24.0",
    "battery.voltage.nominal: 24",
    "device.mfr: CPS",
    "device.model: CP1500PFCLCD",
    "device.serial: 000000000000",
    "device.type: ups",
    "driver.name: usbhid-ups",
    "driver.parameter.pollfreq: 30",
    "driver.parameter.pollinterval: 2",
    "driver.parameter.port: auto",
    "driver.parameter.synchronous: no",
    "driver.version: 2.7.4",
    "driver.version.data: CyberPower HID 0.4",
    "driver.version.internal: 0.41",
    "input.transfer.high: 139",
    "input.transfer.low: 88",
    "input.voltage: 116.0",
    "input.voltage.nominal: 120",
    "output.voltage: 140.0",
    "ups.beeper.status: enabled",
    "ups.delay.shutdown: 20",
    "ups.delay.start: 30",
    "ups.load: 25",
    "ups.mfr: CPS",
    "ups.model: CP1500PFCLCD",
    "ups.productid: 0501",
    "ups.realpower.nominal: 900",
    "ups.serial: 000000000000",
    "ups.status: OL",
    "ups.test.result: Done and passed",
    "ups.timer.shutdown: -60",
    "ups.timer.start: -60",
    "ups.vendorid: 0764",
  }),

  real_ddl_02 = text({
    "battery.charge: 58",
    "battery.charge.low: 10",
    "battery.charge.warning: 20",
    "battery.runtime: 4944",
    "battery.runtime.low: 300",
    "battery.voltage: 24.0",
    "device.model: CP1500PFCLCD",
    "input.transfer.high: 139",
    "input.transfer.low: 88",
    "input.voltage: 120.0",
    "input.voltage.nominal: 120",
    "output.voltage: 136.0",
    "ups.beeper.status: disabled",
    "ups.load: 0",
    "ups.realpower.nominal: 900",
    "ups.status: OL CHRG",
    "ups.test.result: No test initiated",
  }),

  real_error_refused = "Error: Connection failure: Connection refused\n",
  real_error_nohost = "upscli_tryconnect: Host not found: 'no-such-host.invalid'\nError: No such host\n",

  -- The 2.8.5 driver adds firmware, real power, apparent-power rating and
  -- frequencies to what the 2.7.4 dumps show.
  synth_nut285 = text({
    "battery.charge: 100",
    "battery.runtime: 2700",
    "device.model: CP1500PFCLCDa",
    "input.frequency: 60.0",
    "input.voltage: 111.0",
    "input.voltage.nominal: 120",
    "output.frequency: 60.0",
    "output.voltage: 111.0",
    "ups.firmware: CR01802H1711",
    "ups.load: 18",
    "ups.power.nominal: 1500",
    "ups.realpower: 180",
    "ups.realpower.nominal: 1000",
    "ups.status: OL",
  }),

  synth_on_battery = text({
    "battery.charge: 87",
    "battery.runtime: 2280",
    "input.voltage: 0.0",
    "ups.load: 18",
    "ups.status: OB DISCHRG",
  }),

  synth_low_battery = text({
    "battery.charge: 9",
    "battery.runtime: 240",
    "ups.status: OB DISCHRG LB",
  }),

  synth_boost = text({ "ups.status: OL BOOST CHRG" }),
  synth_trim = text({ "ups.status: OL TRIM" }),
  synth_overload_on_battery = text({ "ups.status: OB OVER" }),
  synth_replace_battery = text({ "ups.status: OL RB" }),
  synth_off = text({ "ups.status: OFF" }),

  synth_error_stale = "Error: Data stale\n",
  synth_error_driver = "Error: Driver not connected\n",
  synth_error_unknown = "Error: Unknown UPS\n",

  synth_list = "cyberpower\nrouter-ups\n",
  -- A stray non-name line, to prove only bare names are kept.
  synth_list_with_noise = "some notice: not a name\ncyberpower\n",
}
