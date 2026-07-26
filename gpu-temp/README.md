# GPU Temperature

Configures Noctalia's System Monitor widgets (`sysmon` and `temp`) to display GPU temperature from the `amdgpu` hwmon sensor. Automatically sets the sensor path so the built-in temperature widget works out of the box on AMD GPUs.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rael2pac/gpu-temp` |
| Entries | Service: `gpu-temp` |

## Requirements

- AMD GPU with `amdgpu` driver
- `hwmon` sensor accessible at `/sys/class/hwmon/hwmon*/temp1_input`

## Usage

Enable the plugin and it will automatically configure the GPU temperature sensor for Noctalia's System Monitor widgets. The service runs once at startup to set the sensor path.

No user interaction required — just enable and forget.

## Notes

- Only supports AMD GPUs using the `amdgpu` kernel driver.
- The service reads from `/sys/class/hwmon/hwmon*/name` to find the correct sensor.
- NVIDIA GPUs are not supported by this plugin.
