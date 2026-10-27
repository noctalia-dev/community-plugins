#ifndef DEVICE_H
#define DEVICE_H

#include <string>

// Print every keyboard-capable input device as "<stable path>\t<device name>".
// A /dev/input/by-id path is preferred; event paths are used only when no stable link exists.
void listKeyboardDevices();

// Interactively choose a keyboard device.
std::string findKeyboardDevices();
// Get the input device path from the configuration directory.
std::string getInputDevicePath(std::string &configDir);

// Save the selected input device path.
void saveInputDevice(std::string &configDir);

#endif // DEVICE_H
