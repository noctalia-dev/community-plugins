#define MINIAUDIO_IMPLEMENTATION

#include "audio.h"
#include "analytics.h"

#include <fcntl.h>
#include <iostream>
#include <linux/input.h>
#include <unistd.h>

#include <chrono>
#include <string>

ma_engine engine;

ma_result initializeAudioEngine() {
  return ma_engine_init(NULL, &engine);
}

void uninitializeAudioEngine() {
  ma_engine_uninit(&engine);
}

void playSound(const std::string &soundFile) {
  if (ma_engine_play_sound(&engine, soundFile.c_str(), NULL) != MA_SUCCESS) {
    std::cerr << "Error playing sound: " << soundFile << std::endl;
  }
}

void setVolume(float volume) {
  ma_engine_set_volume(&engine, volume);
}

void runMainLoop(
    const std::string &devicePath,
    const std::unordered_map<int, std::string> &keySoundMap,
    float volume,
    const std::string &soundpackPath,
    bool analyticsOnly,
    bool analyticsEnabled) {

  int fd = open(devicePath.c_str(), O_RDONLY | O_NONBLOCK);

  if (fd < 0) {
    std::cerr << "Failed to open input device: " << devicePath << std::endl;
    return;
  }

  if (!analyticsOnly) {
    setVolume(volume);
    std::cout << "Listening for key events on: " << devicePath << std::endl;
  }

  AnalyticsTracker analytics;
  analytics.setEnabled(analyticsEnabled);

  struct input_event ev{};
  auto lastFlush = std::chrono::steady_clock::now();

  while (true) {
    const ssize_t n = read(fd, &ev, sizeof(ev));

    if (n == static_cast<ssize_t>(sizeof(ev))) {
      if (ev.type == EV_KEY && ev.value == 1) {

        if (analyticsEnabled) {
          analytics.recordKeyPress(static_cast<unsigned int>(ev.code));
        }

        if (!analyticsOnly) {
          const auto it = keySoundMap.find(ev.code);

          if (it != keySoundMap.end()) {
            const std::string soundFile =
                soundpackPath + "/" + it->second;

            playSound(soundFile);
          }
        }
      }
    } else {
      usleep(1000);
    }

    if (analyticsEnabled) {
      const auto now = std::chrono::steady_clock::now();

      if (now - lastFlush >= std::chrono::seconds(5)) {
        analytics.flush();
        lastFlush = now;
      }
    }
  }

  analytics.shutdown();
  close(fd);
}
