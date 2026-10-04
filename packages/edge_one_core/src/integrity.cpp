#include "integrity.hpp"
#include "pinned_manifest.hpp"

#include <array>
#include <fstream>

extern "C" {
#include <sha256/sha256.h>
}

namespace edge_one {
void validate_pinned_manifest(const Manifest &manifest) {
  static const auto pinned = parse_manifest(pinned_manifest_json);
  if (manifest.id != pinned.id || manifest.revision != pinned.revision ||
      manifest.file != pinned.file || manifest.sha256 != pinned.sha256 ||
      manifest.bytes != pinned.bytes || manifest.yes != pinned.yes || manifest.no != pinned.no ||
      manifest.verdict != pinned.verdict || manifest.temperature != pinned.temperature)
    throw Error(503, "Model identity or readout differs from the pinned manifest");
  if (manifest.max_options < 1 || manifest.max_options > pinned.max_options ||
      manifest.max_levels < 2 || manifest.max_levels > pinned.max_levels || manifest.n_ctx < 1 ||
      manifest.n_ctx > pinned.n_ctx)
    throw Error(503, "Runtime limits exceed the pinned model profile");
}

void verify_model_file(const char *path, const std::string &expected, uint64_t bytes) {
  if (!path || !*path)
    throw Error(503, "Model path is empty");
  std::ifstream input(path, std::ios::binary);
  if (!input)
    throw Error(503, "Unable to read local GGUF model");
  sha256_t hash;
  sha256_init(&hash);
  std::array<unsigned char, 65536> buffer;
  uint64_t count = 0;
  while (input) {
    input.read(reinterpret_cast<char *>(buffer.data()), buffer.size());
    const auto size = static_cast<uint64_t>(input.gcount());
    if (size > bytes - count)
      throw Error(503, "GGUF byte count differs from the pinned manifest");
    count += size;
    sha256_update(&hash, buffer.data(), static_cast<size_t>(size));
  }
  if (!input.eof() || count != bytes)
    throw Error(503, "GGUF byte count or read failed");
  std::array<unsigned char, SHA256_DIGEST_SIZE> digest;
  sha256_final(&hash, digest.data());
  std::string actual;
  constexpr char hex[] = "0123456789abcdef";
  for (auto byte : digest) {
    actual += hex[byte >> 4];
    actual += hex[byte & 15];
  }
  if (actual != expected)
    throw Error(503, "GGUF SHA-256 differs from the pinned manifest");
}
} // namespace edge_one
