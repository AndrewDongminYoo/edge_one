#pragma once

#include <cstdint>
#include <functional>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <string>
#include <vector>

namespace edge_one {
using Json = nlohmann::ordered_json;
using Tokens = std::vector<int32_t>;
using Encoder = std::function<Tokens(const std::string &)>;

struct Error : std::runtime_error {
  Error(int32_t code, const std::string &message) : std::runtime_error(message), status(code) {}
  int32_t status;
};

struct Manifest {
  std::string id;
  std::string revision;
  std::string file;
  std::string sha256;
  uint64_t bytes;
  int32_t max_options;
  int32_t max_levels;
  int32_t n_ctx;
  int32_t yes;
  int32_t no;
  int32_t verdict;
  double temperature;
};

struct RenderedQuestion {
  std::string key;
  std::string type;
  Json criteria;
  std::vector<std::string> names;
  Tokens tokens;             // Suffix only; prefix is stored once in RenderedRequest.
  std::vector<size_t> slots; // Verdict positions relative to this suffix.
};

struct RenderedRequest {
  std::string model;
  Tokens prefix;
  std::vector<RenderedQuestion> questions;
  size_t input_tokens = 0; // Prefix once + sum of all suffixes.
};

Json parse_json(const char *text);
Manifest parse_manifest(const char *text);
void validate_request(const Json &request, const Manifest &manifest);
RenderedRequest render_request(const Json &request, const Manifest &manifest,
                               const Encoder &encode);
} // namespace edge_one
