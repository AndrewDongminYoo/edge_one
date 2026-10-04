#pragma once

#include "engine.hpp"

#include <array>

namespace edge_one {
enum class ScoreMode { individual, exact };
using VerdictRows = std::vector<std::array<double, 2>>;

struct ScoreDiagnostics {
  size_t shared_tokens = 0;
  size_t prefix_decoded_tokens = 0;
  size_t sequence_copies = 0;
  size_t decoded_tokens = 0;
  size_t decode_calls = 0;
};

// The llama adapter consumes sparse batch-token indices, never compact row ordinals.
class Decoder {
public:
  virtual ~Decoder() = default;
  virtual void clear() noexcept = 0;
  virtual void remove_branch() = 0;
  virtual void copy_prefix() = 0;
  virtual VerdictRows decode(const Tokens &tokens, size_t position, int32_t sequence,
                             const std::vector<size_t> &slots) = 0;
};

std::vector<double> verdict_probabilities(const VerdictRows &rows, double temperature);
Distributions score_request(Decoder &decoder, const RenderedRequest &request,
                            const Manifest &manifest, size_t microbatch, ScoreMode mode,
                            const std::atomic<bool> &cancelled, ScoreDiagnostics &diagnostics);

// Private diagnostics factory. The exported C API always selects exact mode.
std::unique_ptr<Backend> open_scoring_backend(const char *path, const Manifest &manifest,
                                              ScoreMode mode, ScoreDiagnostics *diagnostics,
                                              Json *profile);
} // namespace edge_one
