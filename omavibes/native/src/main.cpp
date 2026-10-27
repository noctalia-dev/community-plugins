#include "audio.h"
#include "config.h"
#include "device.h"
#include "secure_file.h"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <unistd.h>
#include <unordered_map>

namespace {

void printHelp() {
  std::cout
      << "Usage: wayvibes [options] [soundpack_path]\n"
      << "Options:\n"
      << "  --device              Select input device\n"
      << "  --list-devices        List keyboard-capable input devices\n"
      << "  -v <volume>           Set volume (0.0-10.0) (default: 1.0)\n"
      << "  --background, -bg     Run in background (detached from terminal)\n"
      << "  --analytics-only      Track keyboard analytics without playing sounds\n"
      << "  --no-analytics        Disable analytics for this sound process\n"
      << "  --write-file <path> <data>  Securely write a plugin state/config file\n"
      << "  --help, -h            Show this help message\n"
      << "Note: default soundpack path is './' (current directory)\n"
      << "Example: wayvibes ~/wayvibes/akko_lavender_purples/ -v 3"
      << std::endl;
}

} // namespace

int main(int argc, char *argv[]) {
  std::string soundpackPath = "./";
  float volume = 1.0f;
  std::string configDir;
  bool silent = false;
  bool analyticsOnly = false;
  bool noAnalytics = false;

  const char *xdgConfigHome = std::getenv("XDG_CONFIG_HOME");

  if (xdgConfigHome && *xdgConfigHome) {
    configDir = std::string(xdgConfigHome) + "/wayvibes";
  } else {
    const char *home = std::getenv("HOME");

    if (!home || !*home) {
      std::cerr << "Could not determine HOME directory." << std::endl;
      return 1;
    }

    configDir = std::string(home) + "/.config/wayvibes";
  }

  const bool secureWriteCommand =
      argc == 4 && std::string(argv[1]) == "--write-file";

  if (!secureWriteCommand && !std::filesystem::exists(configDir)) {
    std::filesystem::create_directories(configDir);
  }

  for (int i = 1; i < argc; i++) {
    const std::string argument = argv[i];

    if (argument == "--write-file") {
      if (i + 2 >= argc || !writeFileAtomically(argv[i + 1], argv[i + 2])) {
        std::cerr << "Failed to securely write requested file." << std::endl;
        return 1;
      }
      return 0;

    } else if (argument == "--device") {
      saveInputDevice(configDir);
      return 0;

    } else if (argument == "--list-devices") {
      listKeyboardDevices();
      return 0;
    } else if (argument == "-v" && (i + 1) < argc) {
      try {
        volume = std::stof(argv[i + 1]);
        i++;
      } catch (...) {
        std::cerr
            << "Invalid volume argument. Using default volume (1.0)."
            << std::endl;
      }

    } else if (argument == "--background" || argument == "-bg") {
      silent = true;

    } else if (argument == "--analytics-only") {
      analyticsOnly = true;

    } else if (argument == "--no-analytics") {
      noAnalytics = true;

    } else if (argument == "--help" || argument == "-h") {
      printHelp();
      return 0;

    } else if (!argument.empty() && argument[0] != '-') {
      soundpackPath = argument;

    } else {
      std::cerr << "Unknown argument: " << argument << std::endl;
      printHelp();
      return 1;
    }
  }

  if (analyticsOnly && noAnalytics) {
    std::cerr
        << "--analytics-only and --no-analytics cannot be used together."
        << std::endl;
    return 1;
  }

  if (silent) {
    pid_t pid = fork();

    if (pid < 0) {
      std::cerr << "Failed to fork for background mode." << std::endl;
      return 1;
    }

    if (pid > 0) {
      return 0;
    }

    setsid();

    freopen("/dev/null", "r", stdin);
    freopen("/dev/null", "w", stdout);
    freopen("/dev/null", "w", stderr);
  }

  if (analyticsOnly) {
    std::string devicePath = getInputDevicePath(configDir);

    if (devicePath.empty()) {
      if (silent) {
        return 1;
      }

      std::cout
          << "No device found. Prompting user for a keyboard device."
          << std::endl;
      saveInputDevice(configDir);
      devicePath = getInputDevicePath(configDir);
    }

    if (devicePath.empty()) {
      std::cerr << "No keyboard input device configured." << std::endl;
      return 1;
    }

    const std::unordered_map<int, std::string> emptySoundMap;

    runMainLoop(
        devicePath,
        emptySoundMap,
        0.0f,
        "./",
        true,
        true);

    return 0;
  }

  volume = std::clamp(volume, 0.0f, 10.0f);

  std::string devicePath = getInputDevicePath(configDir);
  if (devicePath.empty()) {
    if (silent) {
      return 1;
    }

    std::cout
        << "No device found. Prompting user for a keyboard device."
        << std::endl;
    saveInputDevice(configDir);
    devicePath = getInputDevicePath(configDir);
  }

  if (devicePath.empty()) {
    std::cerr << "No keyboard input device configured." << std::endl;
    return 1;
  }

  if (initializeAudioEngine() != MA_SUCCESS) {
    if (!silent) {
      std::cerr << "Failed to initialize audio engine" << std::endl;
    }

    return 1;
  }

  if (!silent) {
    std::cout << "Soundpack: " << soundpackPath << std::endl;
  }

  std::unordered_map<int, std::string> keySoundMap =
      loadKeySoundMappings(soundpackPath + "/config.json");


  runMainLoop(
      devicePath,
      keySoundMap,
      volume,
      soundpackPath,
      false,
      !noAnalytics);

  uninitializeAudioEngine();
  return 0;
}
