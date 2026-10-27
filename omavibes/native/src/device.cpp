#include "device.h"
#include "secure_file.h"
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <libevdev-1.0/libevdev/libevdev.h>
#include <string>
#include <unistd.h>
#include <vector>

#define deviceDir "/dev/input/"
// ANSI color codes for terminal styling
#define RESET "\033[0m"
#define BOLD "\033[1m"
#define RED "\033[31m"
#define GREEN "\033[32m"
#define YELLOW "\033[33m"
#define BLUE "\033[34m"
#define CYAN "\033[36m"

namespace {

struct KeyboardDevice {
  std::string eventDevice;
  std::string name;
};

std::vector<KeyboardDevice> findKeyboardDeviceEntries() {
  DIR *dir = opendir(deviceDir);
  if (!dir) {
    std::cerr << RED << "Failed to open /dev/input directory" << RESET << std::endl;
    return {};
  }

  std::vector<KeyboardDevice> devices;
  struct dirent *entry;

  while ((entry = readdir(dir)) != nullptr) {
    if (strncmp(entry->d_name, "event", 5) != 0) {
      continue;
    }

    const std::string eventDevice = entry->d_name;
    const std::string devicePath = deviceDir + eventDevice;
    struct libevdev *dev = nullptr;
    const int fd = open(devicePath.c_str(), O_RDONLY);
    if (fd < 0) {
      continue;
    }

    const int rc = libevdev_new_from_fd(fd, &dev);
    if (rc >= 0 && libevdev_has_event_code(dev, EV_KEY, KEY_A)) {
      devices.push_back({
          eventDevice,
          libevdev_get_name(dev) ? libevdev_get_name(dev) : eventDevice,
      });
    }

    if (dev) {
      libevdev_free(dev);
    }
    close(fd);
  }

  closedir(dir);
  return devices;
}

} // namespace

std::string resolveToByIdPath(const std::string &eventDevice);

void listKeyboardDevices() {
  for (const auto &device : findKeyboardDeviceEntries()) {
    const std::string byIdPath = resolveToByIdPath(device.eventDevice);
    const std::string path =
        byIdPath.empty() ? deviceDir + device.eventDevice : byIdPath;
    std::cout << path << "\t" << device.name << std::endl;
  }
}

std::string findKeyboardDevices() {
  const std::vector<KeyboardDevice> devices = findKeyboardDeviceEntries();
  if (devices.empty()) {
    std::cerr << RED << "No suitable keyboard input devices found!" << RESET << std::endl;
    return "";
  }

  std::cout << CYAN << "Available Keyboard devices:" << RESET << std::endl;
  for (size_t i = 0; i < devices.size(); ++i) {
    std::cout << CYAN << BOLD << i + 1 << ". " << RESET << YELLOW
              << devices[i].name << RESET << " (" << devices[i].eventDevice << ")"
              << std::endl;
  }

  if (devices.size() == 1) {
    std::cout << CYAN << "Selecting this keyboard device." << RESET << std::endl;
    return devices.front().eventDevice;
  }

  while (true) {
    std::cout << CYAN << "Select a keyboard input device (1-" << devices.size()
              << "): " << RESET;
    int choice;
    std::cin >> choice;

    if (choice >= 1 && choice <= static_cast<int>(devices.size())) {
      return devices[choice - 1].eventDevice;
    }

    std::cerr << RED << "Invalid choice. Please try again." << RESET << std::endl;
  }
}

std::string resolveToByIdPath(const std::string &eventDevice) {
  namespace fs = std::filesystem;
  std::string byIdDir = "/dev/input/by-id/";

  try {
    if (!fs::exists(byIdDir)) {
      return ""; // No by-id directory, fallback to event path
    }

    std::string targetPath = fs::canonical(deviceDir + eventDevice);

    for (const auto &entry : fs::directory_iterator(byIdDir)) {
      if (fs::is_symlink(entry)) {
        std::string linkTarget = fs::canonical(entry);

        if (linkTarget == targetPath) {
          return entry.path().string();
        }
      }
    }
  } catch (const std::exception &e) {
    std::cerr << RED << "Error resolving symlink: " << e.what() << RESET << std::endl;
  }

  return ""; // No matching symlink found
}

std::string getInputDevicePath(std::string &configDir) {
  std::string inputFilePath = configDir + "/input_device_path";
  std::ifstream inputFile(inputFilePath);

  if (inputFile.is_open()) {
    std::string devicePath;
    std::getline(inputFile, devicePath);
    inputFile.close();
    return devicePath;
  }

  return "";
}

void saveInputDevice(std::string &configDir) {
  std::string selectedDevice = findKeyboardDevices();
  if (!selectedDevice.empty()) {
    std::string byIdPath = resolveToByIdPath(selectedDevice);
    std::string deviceToSave;

    if (!byIdPath.empty()) {
      std::cout << GREEN << "\nUsing by-id path..." << RESET << std::endl;
      deviceToSave = byIdPath;
    } else {
      std::cout << YELLOW << BOLD
                << "\nNo by-id symlink found, using non-persistent event path..." << RESET
                << std::endl;
      deviceToSave = deviceDir + selectedDevice;
    }

    if (!writeFileAtomically(configDir + "/input_device_path", deviceToSave)) {
      std::cerr << RED << "Failed to securely save device path." << RESET << std::endl;
      return;
    }
    std::cout << GREEN << "Device path saved: " << deviceToSave << RESET << std::endl;
  } else {
    std::cerr << RED << "No device selected. Exiting." << RESET << std::endl;
    exit(1);
  }
}
