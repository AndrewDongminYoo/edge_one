#pragma once

#include "core.hpp"
#include "edge_one.h"

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>

namespace edge_one {
using Distributions = std::vector<std::vector<double>>;

// Private C++ seam, not part of the exported C ABI. The backend supplies probabilities
// from verdict logits; test implementations are linked only into test binaries.
class Backend {
public:
  virtual ~Backend() = default;
  virtual Tokens encode(const std::string &text) = 0;
  virtual Distributions score(const RenderedRequest &request,
                              const std::atomic<bool> &cancelled) = 0;
};
std::unique_ptr<Backend> open_backend(const char *path, const Manifest &manifest);
Json make_response(const RenderedRequest &request, const Manifest &manifest,
                   const Distributions &distributions);
} // namespace edge_one

struct eo_engine {
  eo_engine(edge_one::Manifest configuration, std::unique_ptr<edge_one::Backend> implementation)
      : manifest(std::move(configuration)), backend(std::move(implementation)) {}
  edge_one::Manifest manifest;
  std::unique_ptr<edge_one::Backend> backend;
  std::mutex mutex;
  std::condition_variable idle;
  bool active = false;
  bool closing = false;
  std::atomic<bool> cancelled{false};
};
