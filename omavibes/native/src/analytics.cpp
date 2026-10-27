#include "analytics.h"
#include "secure_file.h"

#include <linux/input-event-codes.h>

#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <pwd.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {
using Clock = std::chrono::system_clock;

struct ParsedData {
  std::map<std::string, std::uint64_t> dailyWords;
  std::map<std::string, std::uint64_t> dailyTypingSeconds;
  std::map<std::string, std::uint64_t> dailyTrackedSeconds;
  std::string trackingMode = "onlyWhenSound";

  // Lifetime aggregate key-press counts only, keyed by a stable
  // physical-key label (e.g. "A", "SPACE", "BACKSPACE"). Never
  // per-day, never ordered, never timestamped. Absent in files
  // written before this field existed; treated as empty on load.
  std::map<std::string, std::uint64_t> keyCounts;
};

std::string jsonEscape(const std::string &value) {
  std::string out;
  out.reserve(value.size() + 2);

  for (char c : value) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        out += c;
        break;
    }
  }

  return out;
}

std::string extractObject(const std::string &json,
                          const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  const std::size_t keyPos = json.find(needle);

  if (keyPos == std::string::npos) {
    return {};
  }

  const std::size_t colon = json.find(':', keyPos + needle.size());
  if (colon == std::string::npos) {
    return {};
  }

  const std::size_t objectStart = json.find('{', colon + 1);
  if (objectStart == std::string::npos) {
    return {};
  }

  int depth = 0;
  bool inString = false;
  bool escaped = false;

  for (std::size_t i = objectStart; i < json.size(); ++i) {
    const char c = json[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }

    if (c == '"') {
      inString = true;
      continue;
    }

    if (c == '{') {
      ++depth;
    } else if (c == '}') {
      --depth;
      if (depth == 0) {
        return json.substr(objectStart, i - objectStart + 1);
      }
    }
  }

  return {};
}

std::map<std::string, std::uint64_t> parseNumberObject(
    const std::string &object) {
  std::map<std::string, std::uint64_t> result;

  std::size_t pos = 0;

  while (pos < object.size()) {
    const std::size_t keyStart = object.find('"', pos);
    if (keyStart == std::string::npos) {
      break;
    }

    const std::size_t keyEnd = object.find('"', keyStart + 1);
    if (keyEnd == std::string::npos) {
      break;
    }

    const std::string key = object.substr(
        keyStart + 1, keyEnd - keyStart - 1);

    const std::size_t colon = object.find(':', keyEnd + 1);
    if (colon == std::string::npos) {
      break;
    }

    std::size_t numberStart = colon + 1;
    while (numberStart < object.size() &&
           std::isspace(static_cast<unsigned char>(object[numberStart]))) {
      ++numberStart;
    }

    std::size_t numberEnd = numberStart;
    while (numberEnd < object.size() &&
           std::isdigit(static_cast<unsigned char>(object[numberEnd]))) {
      ++numberEnd;
    }

    if (numberEnd > numberStart) {
      try {
        const auto value = std::stoull(
            object.substr(numberStart, numberEnd - numberStart));
        result[key] = value;
      } catch (...) {
        // Ignore malformed individual entries.
      }
    }

    pos = numberEnd;
    if (pos == numberStart) {
      ++pos;
    }
  }

  return result;
}

std::string parseStringValue(const std::string &json,
                             const std::string &key,
                             const std::string &fallback) {
  const std::string needle = "\"" + key + "\"";
  const std::size_t keyPos = json.find(needle);

  if (keyPos == std::string::npos) {
    return fallback;
  }

  const std::size_t colon = json.find(':', keyPos + needle.size());
  if (colon == std::string::npos) {
    return fallback;
  }

  const std::size_t quoteStart = json.find('"', colon + 1);
  if (quoteStart == std::string::npos) {
    return fallback;
  }

  const std::size_t quoteEnd = json.find('"', quoteStart + 1);
  if (quoteEnd == std::string::npos) {
    return fallback;
  }

  return json.substr(quoteStart + 1, quoteEnd - quoteStart - 1);
}

ParsedData loadData(const std::string &path) {
  ParsedData data;
  const std::string json = readFileSecure(path);

  if (json.empty()) {
    return data;
  }

  data.dailyWords = parseNumberObject(
      extractObject(json, "dailyWords"));

  data.dailyTypingSeconds = parseNumberObject(
      extractObject(json, "dailyTypingSeconds"));

  data.dailyTrackedSeconds = parseNumberObject(
      extractObject(json, "dailyTrackedSeconds"));

  // Older analytics files simply won't contain this key; extractObject
  // returns an empty string in that case and parseNumberObject returns
  // an empty map, which is exactly the desired backward-compatible
  // default (zero counts for every key).
  data.keyCounts = parseNumberObject(
      extractObject(json, "keyCounts"));

  const std::string mode =
      parseStringValue(json, "trackingMode", data.trackingMode);

  if (mode == "onlyWhenSound" || mode == "always") {
    data.trackingMode = mode;
  }

  return data;
}

std::string serializeNumberObject(
    const std::map<std::string, std::uint64_t> &data) {
  std::ostringstream out;
  out << "{";

  bool first = true;
  for (const auto &[key, value] : data) {
    if (!first) {
      out << ",";
    }

    first = false;
    out << "\"" << jsonEscape(key) << "\":" << value;
  }

  out << "}";
  return out.str();
}

std::string serializeData(const ParsedData &data) {
  std::ostringstream out;

  out << "{";
  out << "\"dailyWords\":"
      << serializeNumberObject(data.dailyWords) << ",";
  out << "\"dailyTypingSeconds\":"
      << serializeNumberObject(data.dailyTypingSeconds) << ",";
  out << "\"dailyTrackedSeconds\":"
      << serializeNumberObject(data.dailyTrackedSeconds) << ",";
  out << "\"keyCounts\":"
      << serializeNumberObject(data.keyCounts) << ",";
  out << "\"trackingMode\":\""
      << jsonEscape(data.trackingMode) << "\"";
  out << "}";

  return out.str();
}

std::int64_t nowEpochSeconds() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             Clock::now().time_since_epoch())
      .count();
}

std::tm localTime(std::time_t value) {
  std::tm result{};

#if defined(_POSIX_VERSION)
  localtime_r(&value, &result);
#else
  const std::tm *ptr = std::localtime(&value);
  if (ptr) {
    result = *ptr;
  }
#endif

  return result;
}

std::string dateKeyFromEpoch(std::int64_t epochSeconds) {
  const std::time_t time = static_cast<std::time_t>(epochSeconds);
  const std::tm tm = localTime(time);

  char buffer[11]{};
  std::strftime(buffer, sizeof(buffer), "%Y-%m-%d", &tm);
  return buffer;
}

std::int64_t nextLocalMidnight(std::int64_t epochSeconds) {
  const std::time_t currentTime =
      static_cast<std::time_t>(epochSeconds);
  std::tm tm = localTime(currentTime);

  tm.tm_hour = 0;
  tm.tm_min = 0;
  tm.tm_sec = 0;
  tm.tm_mday += 1;
  tm.tm_isdst = -1;

  const std::time_t result = std::mktime(&tm);
  return static_cast<std::int64_t>(result);
}

bool isWordKey(unsigned int code) {
  // Alphabetic keys. Linux input key codes are not a contiguous
  // alphabetical range, so enumerate the letter codes explicitly.
  switch (code) {
    case KEY_A:
    case KEY_B:
    case KEY_C:
    case KEY_D:
    case KEY_E:
    case KEY_F:
    case KEY_G:
    case KEY_H:
    case KEY_I:
    case KEY_J:
    case KEY_K:
    case KEY_L:
    case KEY_M:
    case KEY_N:
    case KEY_O:
    case KEY_P:
    case KEY_Q:
    case KEY_R:
    case KEY_S:
    case KEY_T:
    case KEY_U:
    case KEY_V:
    case KEY_W:
    case KEY_X:
    case KEY_Y:
    case KEY_Z:
      return true;

    // Number row.
    case KEY_1:
    case KEY_2:
    case KEY_3:
    case KEY_4:
    case KEY_5:
    case KEY_6:
    case KEY_7:
    case KEY_8:
    case KEY_9:
    case KEY_0:
      return true;

    // Numpad digits.
    case KEY_KP1:
    case KEY_KP2:
    case KEY_KP3:
    case KEY_KP4:
    case KEY_KP5:
    case KEY_KP6:
    case KEY_KP7:
    case KEY_KP8:
    case KEY_KP9:
    case KEY_KP0:
      return true;

    case KEY_KPDOT:
      return true;

    default:
      break;
  }

  // Punctuation that can occur inside a word.
  switch (code) {
    case KEY_MINUS:
    case KEY_EQUAL:
    case KEY_LEFTBRACE:
    case KEY_RIGHTBRACE:
    case KEY_BACKSLASH:
    case KEY_SEMICOLON:
    case KEY_APOSTROPHE:
    case KEY_GRAVE:
    case KEY_COMMA:
    case KEY_DOT:
    case KEY_SLASH:
      return true;

    default:
      return false;
  }
}

bool isWordBoundary(unsigned int code) {
  return code == KEY_SPACE ||
         code == KEY_ENTER ||
         code == KEY_KPENTER ||
         code == KEY_TAB;
}

bool isWordBackspace(unsigned int code) {
  return code == KEY_BACKSPACE;
}

// Maps a Linux input-event key code to a stable, layout-independent
// physical-key label for aggregate counting only. This is deliberately
// NOT a character/text conversion: KEY_A always maps to "A" regardless
// of keyboard layout, and there is no way to recover typed text, word
// order, or timing from the resulting counters.
std::string physicalKeyLabel(unsigned int code) {
  switch (code) {
    // Letters
    case KEY_A: return "A";
    case KEY_B: return "B";
    case KEY_C: return "C";
    case KEY_D: return "D";
    case KEY_E: return "E";
    case KEY_F: return "F";
    case KEY_G: return "G";
    case KEY_H: return "H";
    case KEY_I: return "I";
    case KEY_J: return "J";
    case KEY_K: return "K";
    case KEY_L: return "L";
    case KEY_M: return "M";
    case KEY_N: return "N";
    case KEY_O: return "O";
    case KEY_P: return "P";
    case KEY_Q: return "Q";
    case KEY_R: return "R";
    case KEY_S: return "S";
    case KEY_T: return "T";
    case KEY_U: return "U";
    case KEY_V: return "V";
    case KEY_W: return "W";
    case KEY_X: return "X";
    case KEY_Y: return "Y";
    case KEY_Z: return "Z";

    // Number row
    case KEY_1: return "1";
    case KEY_2: return "2";
    case KEY_3: return "3";
    case KEY_4: return "4";
    case KEY_5: return "5";
    case KEY_6: return "6";
    case KEY_7: return "7";
    case KEY_8: return "8";
    case KEY_9: return "9";
    case KEY_0: return "0";

    // Common keys
    case KEY_SPACE: return "SPACE";
    case KEY_BACKSPACE: return "BACKSPACE";
    case KEY_ENTER: return "ENTER";
    case KEY_KPENTER: return "ENTER";
    case KEY_TAB: return "TAB";
    case KEY_ESC: return "ESC";

    // Modifiers
    case KEY_LEFTSHIFT: return "SHIFT";
    case KEY_RIGHTSHIFT: return "SHIFT";
    case KEY_LEFTCTRL: return "CTRL";
    case KEY_RIGHTCTRL: return "CTRL";
    case KEY_LEFTALT: return "ALT";
    case KEY_RIGHTALT: return "ALT";
    case KEY_LEFTMETA: return "META";
    case KEY_RIGHTMETA: return "META";
    case KEY_CAPSLOCK: return "CAPSLOCK";

    // Punctuation
    case KEY_MINUS: return "MINUS";
    case KEY_EQUAL: return "EQUAL";
    case KEY_LEFTBRACE: return "LEFTBRACE";
    case KEY_RIGHTBRACE: return "RIGHTBRACE";
    case KEY_BACKSLASH: return "BACKSLASH";
    case KEY_SEMICOLON: return "SEMICOLON";
    case KEY_APOSTROPHE: return "APOSTROPHE";
    case KEY_GRAVE: return "GRAVE";
    case KEY_COMMA: return "COMMA";
    case KEY_DOT: return "DOT";
    case KEY_SLASH: return "SLASH";

    // Navigation
    case KEY_UP: return "UP";
    case KEY_DOWN: return "DOWN";
    case KEY_LEFT: return "LEFT";
    case KEY_RIGHT: return "RIGHT";
    case KEY_DELETE: return "DELETE";
    case KEY_HOME: return "HOME";
    case KEY_END: return "END";
    case KEY_PAGEUP: return "PAGEUP";
    case KEY_PAGEDOWN: return "PAGEDOWN";

    default:
      return "OTHER";
  }
}

} // namespace

struct AnalyticsTracker::Impl {
  explicit Impl(const std::string &path)
      : statePath(path.empty()
                      ? AnalyticsTracker::defaultStatePath()
                      : path),
        data(loadData(statePath)) {}

  std::string statePath;
  ParsedData data;

  bool enabled = false;
  bool dirty = false;

  std::uint64_t currentWordLength = 0;

  bool hasPreviousKey = false;
  std::int64_t previousKeyEpoch = 0;

  bool hasPendingFlush = false;
};

AnalyticsTracker::AnalyticsTracker(const std::string &statePath)
    : impl_(new Impl(statePath)) {}

AnalyticsTracker::~AnalyticsTracker() {
  shutdown();
  delete impl_;
  impl_ = nullptr;
}

std::string AnalyticsTracker::defaultStatePath() {
  const char *xdgStateHome = std::getenv("XDG_STATE_HOME");

  if (xdgStateHome && *xdgStateHome && xdgStateHome[0] == '/') {
    return std::string(xdgStateHome) +
           "/omarchy/omavibes-analytics.json";
  }

  // Do not trust HOME for security-sensitive state paths. Resolve the real
  // home directory from the account database instead.
  const long configuredSize = sysconf(_SC_GETPW_R_SIZE_MAX);
  const std::size_t bufferSize =
      configuredSize > 0 ? static_cast<std::size_t>(configuredSize) : 16384U;

  std::vector<char> buffer(bufferSize);
  struct passwd passwordEntry{};
  struct passwd *result = nullptr;

  if (getpwuid_r(getuid(),
                 &passwordEntry,
                 buffer.data(),
                 buffer.size(),
                 &result) == 0 &&
      result &&
      result->pw_dir &&
      result->pw_dir[0] == '/') {
    return std::string(result->pw_dir) +
           "/.local/state/omarchy/omavibes-analytics.json";
  }

  // Returning an empty path disables persistence rather than falling back to
  // an attacker-controlled working directory.
  return {};
}

void AnalyticsTracker::setEnabled(bool enabled) {
  if (impl_->enabled == enabled) {
    return;
  }

  impl_->enabled = enabled;

  if (!enabled) {
    // Do not carry a word across disabled periods.
    impl_->currentWordLength = 0;
    impl_->hasPreviousKey = false;
    impl_->previousKeyEpoch = 0;
    flush();
  }
}

bool AnalyticsTracker::isEnabled() const {
  return impl_->enabled;
}

void AnalyticsTracker::recordKeyPress(unsigned int keyCode) {
  if (!impl_->enabled) {
    return;
  }

  const std::int64_t now = nowEpochSeconds();

  if (impl_->hasPreviousKey) {
    const std::int64_t gap =
        now - impl_->previousKeyEpoch;

    if (gap > 0 &&
        gap <= AnalyticsTracker::IDLE_THRESHOLD_SECONDS) {
      std::int64_t activeSeconds = 0;
      std::int64_t idleSeconds = 0;

      if (gap <= AnalyticsTracker::ACTIVE_THRESHOLD_SECONDS) {
        activeSeconds = gap;
      } else {
        idleSeconds = gap - AnalyticsTracker::ACTIVE_THRESHOLD_SECONDS;
        activeSeconds = AnalyticsTracker::ACTIVE_THRESHOLD_SECONDS;
      }

      // Allocate the interval across real local calendar dates.
      // This matters when typing crosses midnight.
      auto allocateInterval =
          [this, activeSeconds, idleSeconds, now, gap](
              std::int64_t startEpoch,
              std::int64_t endEpoch) {
            if (endEpoch <= startEpoch) {
              return;
            }

            std::int64_t cursor = startEpoch;
            const std::int64_t totalDuration = endEpoch - startEpoch;

            std::int64_t activeRemaining = activeSeconds;
            std::int64_t idleRemaining = idleSeconds;

            while (cursor < endEpoch) {
              const std::int64_t boundary =
                  nextLocalMidnight(cursor);

              const std::int64_t chunkEnd =
                  std::min(endEpoch, boundary);

              const std::int64_t chunk =
                  chunkEnd - cursor;

              const std::int64_t activeChunk =
                  (totalDuration > 0)
                      ? std::min(
                            activeRemaining,
                            chunk)
                      : 0;

              activeRemaining -= activeChunk;

              const std::int64_t idleChunk =
                  (totalDuration > 0)
                      ? std::min(
                            idleRemaining,
                            chunk - activeChunk)
                      : 0;

              idleRemaining -= idleChunk;

              const std::string key =
                  dateKeyFromEpoch(cursor);

              impl_->data.dailyTypingSeconds[key] +=
                  static_cast<std::uint64_t>(
                      std::max<std::int64_t>(0, activeChunk));

              impl_->data.dailyTrackedSeconds[key] +=
                  static_cast<std::uint64_t>(
                      std::max<std::int64_t>(0,
                                             activeChunk +
                                             idleChunk));

              cursor = chunkEnd;
            }

            (void)now;
            (void)gap;
          };

      allocateInterval(
          impl_->previousKeyEpoch,
          now);

      impl_->dirty = true;
    }
  }

  if (isWordBoundary(keyCode)) {
    if (impl_->currentWordLength > 0) {
      const std::string day = dateKeyFromEpoch(now);
      impl_->data.dailyWords[day] += 1;
      impl_->dirty = true;
    }

    impl_->currentWordLength = 0;
  } else if (isWordBackspace(keyCode)) {
    if (impl_->currentWordLength > 0) {
      --impl_->currentWordLength;
    }
  } else if (isWordKey(keyCode)) {
    ++impl_->currentWordLength;
  }

  // Aggregate-only key counting. Only a running integer per physical
  // key label is incremented — no text, no key sequence, no per-key
  // timestamp is stored anywhere.
  impl_->data.keyCounts[physicalKeyLabel(keyCode)] += 1;
  impl_->dirty = true;

  impl_->hasPreviousKey = true;
  impl_->previousKeyEpoch = now;

  // Persist periodically from the caller rather than forcing a disk write
  // on every single key press.
  impl_->hasPendingFlush = true;
}

void AnalyticsTracker::flush() {
  if (!impl_->dirty && !impl_->hasPendingFlush) {
    return;
  }

  // Reload the current tracking-mode field so this component never
  // overwrites the user's QML-selected mode.
  const ParsedData diskData = loadData(impl_->statePath);
  impl_->data.trackingMode = diskData.trackingMode;

  const std::string json = serializeData(impl_->data);

  if (writeFileAtomically(impl_->statePath, json)) {
    impl_->dirty = false;
    impl_->hasPendingFlush = false;
  }
}

void AnalyticsTracker::shutdown() {
  if (!impl_) {
    return;
  }

  flush();

  impl_->currentWordLength = 0;
  impl_->hasPreviousKey = false;
  impl_->previousKeyEpoch = 0;
}

std::uint64_t AnalyticsTracker::wordsToday() const {
  const std::string today =
      dateKeyFromEpoch(nowEpochSeconds());

  const auto it = impl_->data.dailyWords.find(today);
  return it == impl_->data.dailyWords.end() ? 0 : it->second;
}

std::uint64_t AnalyticsTracker::typingSecondsToday() const {
  const std::string today =
      dateKeyFromEpoch(nowEpochSeconds());

  const auto it =
      impl_->data.dailyTypingSeconds.find(today);

  return it == impl_->data.dailyTypingSeconds.end()
             ? 0
             : it->second;
}

std::uint64_t AnalyticsTracker::idleSecondsToday() const {
  const std::string today =
      dateKeyFromEpoch(nowEpochSeconds());

  const auto tracked =
      impl_->data.dailyTrackedSeconds.find(today);

  const auto typing =
      impl_->data.dailyTypingSeconds.find(today);

  const std::uint64_t trackedValue =
      tracked == impl_->data.dailyTrackedSeconds.end()
          ? 0
          : tracked->second;

  const std::uint64_t typingValue =
      typing == impl_->data.dailyTypingSeconds.end()
          ? 0
          : typing->second;

  return trackedValue > typingValue
             ? trackedValue - typingValue
             : 0;
}

std::uint64_t AnalyticsTracker::trackedSecondsToday() const {
  const std::string today =
      dateKeyFromEpoch(nowEpochSeconds());

  const auto it =
      impl_->data.dailyTrackedSeconds.find(today);

  return it == impl_->data.dailyTrackedSeconds.end()
             ? 0
             : it->second;
}

std::uint64_t AnalyticsTracker::totalKeyPresses() const {
  std::uint64_t total = 0;
  for (const auto &[label, count] : impl_->data.keyCounts) {
    total += count;
  }
  return total;
}

std::uint64_t AnalyticsTracker::keyPressCount(
    const std::string &keyLabel) const {
  const auto it = impl_->data.keyCounts.find(keyLabel);
  return it == impl_->data.keyCounts.end() ? 0 : it->second;
}
