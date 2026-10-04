#pragma once

#include "core.hpp"

#include <cstdio>
#include <memory>

namespace edge_one {
void validate_pinned_manifest(const Manifest &manifest);
struct CloseModelFile {
  void operator()(FILE *file) const noexcept { std::fclose(file); }
};
using ModelFile = std::unique_ptr<FILE, CloseModelFile>;
// Caller owns immutable backing bytes through the complete model lifetime.
ModelFile open_verified_model_file(const char *path, const std::string &sha256, uint64_t bytes);
void verify_model_file(const char *path, const std::string &sha256, uint64_t bytes);
} // namespace edge_one
