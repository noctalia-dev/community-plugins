#ifndef CONFIG_H
#define CONFIG_H

#include <string>
#include <unordered_map>

// Function to load the key-sound mappings from a JSON configuration file
std::unordered_map<int, std::string> loadKeySoundMappings(const std::string &configPath);

#endif // CONFIG_H