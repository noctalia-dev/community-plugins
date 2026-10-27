#include "secure_file.h"

#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <filesystem>
#include <sstream>
#include <string>

namespace {

bool isSafeDirectory(const struct stat &st) {
  if (!S_ISDIR(st.st_mode)) {
    return false;
  }

  const uid_t currentUid = getuid();
  if (st.st_uid != currentUid && st.st_uid != 0) {
    return false;
  }

  if ((st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
    return st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0;
  }

  return true;
}

bool statDirectoryFd(int fd) {
  struct stat st{};
  return fstat(fd, &st) == 0 && isSafeDirectory(st);
}

bool openSafeDirectory(const std::filesystem::path &path,
                       bool createMissing,
                       int &outFd) {
  namespace fs = std::filesystem;

  outFd = -1;

  const bool absolute = path.is_absolute();
  const int baseFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW;
  int currentFd = open(absolute ? "/" : ".", baseFlags);
  if (currentFd == -1 || !statDirectoryFd(currentFd)) {
    if (currentFd != -1) {
      close(currentFd);
    }
    return false;
  }

  try {
    for (const fs::path &componentPath : path) {
      const std::string component = componentPath.string();

      if (component.empty() || component == "/" || component == ".") {
        continue;
      }

      if (component == "..") {
        close(currentFd);
        return false;
      }

      int nextFd = openat(currentFd, component.c_str(), baseFlags);

      if (nextFd == -1 && errno == ENOENT && createMissing) {
        if (mkdirat(currentFd, component.c_str(), 0700) != 0 &&
            errno != EEXIST) {
          close(currentFd);
          return false;
        }

        nextFd = openat(currentFd, component.c_str(), baseFlags);
      }

      if (nextFd == -1 || !statDirectoryFd(nextFd)) {
        if (nextFd != -1) {
          close(nextFd);
        }
        close(currentFd);
        return false;
      }

      close(currentFd);
      currentFd = nextFd;
    }
  } catch (...) {
    close(currentFd);
    return false;
  }

  outFd = currentFd;
  return true;
}

bool splitTargetPath(const std::string &path,
                     std::filesystem::path &parent,
                     std::string &filename) {
  namespace fs = std::filesystem;

  if (path.empty()) {
    return false;
  }

  const fs::path target(path);
  parent = target.parent_path();
  filename = target.filename().string();

  if (filename.empty() || filename == "." || filename == "..") {
    return false;
  }

  return true;
}

std::string readFileSecureImpl(const std::string &path) {
  namespace fs = std::filesystem;

  fs::path parent;
  std::string filename;
  if (!splitTargetPath(path, parent, filename)) {
    return {};
  }

  int dirFd = -1;
  if (!openSafeDirectory(parent, false, dirFd)) {
    return {};
  }

  const int fd = openat(dirFd, filename.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  close(dirFd);

  if (fd == -1) {
    return {};
  }

  struct stat st{};
  if (fstat(fd, &st) != 0 ||
      !S_ISREG(st.st_mode) ||
      st.st_uid != getuid() ||
      (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
    close(fd);
    return {};
  }

  std::string result;
  char buffer[8192];

  while (true) {
    const ssize_t count = read(fd, buffer, sizeof(buffer));

    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      close(fd);
      return {};
    }

    if (count == 0) {
      break;
    }

    result.append(buffer, static_cast<std::size_t>(count));
  }

  close(fd);
  return result;
}

std::string makeTempName(const std::string &targetName, std::size_t attempt) {
  static std::atomic<unsigned long long> counter{0};
  const unsigned long long sequence = counter.fetch_add(1);

  std::ostringstream name;
  name << "." << targetName
       << ".tmp-" << static_cast<unsigned long long>(getpid())
       << "-" << sequence
       << "-" << attempt;
  return name.str();
}

int createExclusiveTemp(int dirFd,
                        const std::string &targetName,
                        std::string &tempName) {
  constexpr std::size_t kAttempts = 64;

  for (std::size_t attempt = 0; attempt < kAttempts; ++attempt) {
    tempName = makeTempName(targetName, attempt);

    const int fd = openat(dirFd,
                          tempName.c_str(),
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                          0600);

    if (fd >= 0) {
      return fd;
    }

    if (errno != EEXIST) {
      break;
    }
  }

  tempName.clear();
  return -1;
}

bool writeFileAtomicallyImpl(const std::string &path, const std::string &data) {
  namespace fs = std::filesystem;

  try {
    fs::path parent;
    std::string targetName;
    if (!splitTargetPath(path, parent, targetName)) {
      return false;
    }

    int dirFd = -1;
    if (!openSafeDirectory(parent, true, dirFd)) {
      return false;
    }

    std::string tempName;
    const int fd = createExclusiveTemp(dirFd, targetName, tempName);
    if (fd == -1) {
      close(dirFd);
      return false;
    }

    bool success = false;
    bool fdClosed = false;

    do {
      if (fchmod(fd, 0600) != 0) {
        break;
      }

      const char *buffer = data.data();
      std::size_t remaining = data.size();

      while (remaining > 0) {
        const ssize_t written = write(fd, buffer, remaining);

        if (written < 0) {
          if (errno == EINTR) {
            continue;
          }
          break;
        }

        if (written == 0) {
          break;
        }

        buffer += written;
        remaining -= static_cast<std::size_t>(written);
      }

      if (remaining != 0) {
        break;
      }

      if (fsync(fd) != 0) {
        break;
      }

      if (close(fd) != 0) {
        fdClosed = true;
        break;
      }
      fdClosed = true;

      if (renameat(dirFd, tempName.c_str(), dirFd, targetName.c_str()) != 0) {
        break;
      }

      if (fsync(dirFd) != 0) {
        break;
      }

      success = true;
    } while (false);

    if (!fdClosed) {
      close(fd);
    }

    if (!success) {
      unlinkat(dirFd, tempName.c_str(), 0);
    }

    close(dirFd);
    return success;
  } catch (...) {
    return false;
  }
}

} // namespace

std::string readFileSecure(const std::string &path) {
  return readFileSecureImpl(path);
}

bool writeFileAtomically(const std::string &path, const std::string &data) {
  return writeFileAtomicallyImpl(path, data);
}
