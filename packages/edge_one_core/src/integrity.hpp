#pragma once

#include "core.hpp"

namespace edge_one {
void validate_pinned_manifest(const Manifest &manifest);
void verify_model_file(const char *path, const std::string &sha256, uint64_t bytes);
} // namespace edge_one
