#ifndef OMAVIBES_ANALYTICS_H
#define OMAVIBES_ANALYTICS_H

#include <cstdint>
#include <string>

class AnalyticsTracker {
public:
  // Input-event timing rules used by the analytics engine.
  // A pause of <= 5 seconds is treated as active typing.
  // A pause of > 5 and <= 60 seconds is treated as idle time.
  // A pause longer than 60 seconds is ignored.
  static constexpr std::int64_t ACTIVE_THRESHOLD_SECONDS = 5;
  static constexpr std::int64_t IDLE_THRESHOLD_SECONDS = 60;

  explicit AnalyticsTracker(
      const std::string &statePath = std::string());

  ~AnalyticsTracker();

  AnalyticsTracker(const AnalyticsTracker &) = delete;
  AnalyticsTracker &operator=(const AnalyticsTracker &) = delete;

  // Enable/disable collection without destroying the tracker.
  void setEnabled(bool enabled);
  bool isEnabled() const;

  // Called by the keyboard event loop for every key press.
  //
  // keyCode is a Linux input-event key code (for example KEY_SPACE,
  // KEY_BACKSPACE, KEY_ENTER, KEY_TAB). The implementation deliberately
  // stores no actual character or typed text.
  void recordKeyPress(unsigned int keyCode);

  // Persist in-memory statistics to the local analytics file.
  // Safe to call periodically; the implementation should avoid unnecessary
  // writes where possible.
  void flush();

  // Force persistence and close the current active typing state.
  void shutdown();

  // The UI can use these values later if we expose lightweight runtime
  // information directly from the process.
  std::uint64_t wordsToday() const;
  std::uint64_t typingSecondsToday() const;
  std::uint64_t idleSecondsToday() const;
  std::uint64_t trackedSecondsToday() const;

  // Aggregate key-press counters only. No typed text, sequences, or
  // per-key timestamps are stored.
  std::uint64_t totalKeyPresses() const;
  std::uint64_t keyPressCount(const std::string &keyLabel) const;

private:
  struct DailyStats {
    std::uint64_t words = 0;
    std::uint64_t typingSeconds = 0;
    std::uint64_t idleSeconds = 0;
    std::uint64_t trackedSeconds = 0;
  };

  // Opaque implementation details stay out of the public header.
  struct Impl;
  Impl *impl_;

  // Resolve the default location:
  // $XDG_STATE_HOME/omarchy/omavibes-analytics.json
  // or ~/.local/state/omarchy/omavibes-analytics.json
  static std::string defaultStatePath();
};

#endif // OMAVIBES_ANALYTICS_H
