#ifndef OMAVIBES_SECURE_FILE_H
#define OMAVIBES_SECURE_FILE_H

#include <string>

// Read a regular file only after validating every parent directory without
// following symlinks and checking ownership/permissions.
std::string readFileSecure(const std::string &path);

// Write a file using owner-checked no-follow directories, exclusive staging,
// and an atomic rename into place.
bool writeFileAtomically(const std::string &path, const std::string &data);

#endif // OMAVIBES_SECURE_FILE_H
