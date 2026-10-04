#include "scorer.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace edge_one {
std::vector<double> verdict_probabilities(const VerdictRows &rows, double temperature) {
  if (rows.empty() || !std::isfinite(temperature) || temperature <= 0)
    throw Error(503, "Invalid verdict readout configuration");
  std::vector<double> values;
  for (const auto &row : rows) {
    const double value = (row[0] - row[1]) / temperature;
    if (!std::isfinite(row[0]) || !std::isfinite(row[1]) || !std::isfinite(value))
      throw Error(503, "Nonfinite verdict logits");
    values.push_back(value);
  }
  const double maximum = *std::max_element(values.begin(), values.end());
  double sum = 0;
  for (auto &value : values) {
    value = std::exp(value - maximum);
    sum += value;
  }
  for (auto &value : values)
    value /= sum;
  return values;
}

Distributions score_request(Decoder &decoder, const RenderedRequest &request,
                            const Manifest &manifest, size_t microbatch, ScoreMode mode,
                            const std::atomic<bool> &cancelled, ScoreDiagnostics &diagnostics) {
  struct Cleanup {
    Decoder &decoder;
    ~Cleanup() { decoder.clear(); }
  } cleanup{decoder};
  decoder.clear();
  diagnostics = {};
  auto check_cancelled = [&] {
    if (cancelled.load())
      throw Error(499, "Evaluation cancelled");
  };
  check_cancelled();
  if (microbatch == 0)
    throw Error(503, "Invalid physical microbatch size");
  const size_t prefix = request.prefix.size();
  const auto budget = static_cast<size_t>(manifest.n_ctx);
  size_t total = prefix;
  if (prefix > budget || request.questions.empty())
    throw Error(422, "Invalid rendered request");
  for (const auto &question : request.questions) {
    if (question.tokens.size() > budget - total || question.slots.empty() ||
        question.slots.size() != question.names.size() || question.slots.size() > 26)
      throw Error(422, "Invalid rendered question or token budget");
    total += question.tokens.size();
    for (size_t i = 0; i < question.slots.size(); ++i) {
      const size_t slot = question.slots[i];
      if (slot >= question.tokens.size() || question.tokens[slot] != manifest.verdict ||
          (i && slot <= question.slots[i - 1]))
        throw Error(422, "Invalid rendered verdict slot");
    }
  }
  const size_t shared = mode == ScoreMode::exact && request.questions.size() > 1
                            ? prefix / microbatch * microbatch
                            : 0;
  auto decode = [&](const Tokens &tokens, size_t position, int32_t sequence,
                    const std::vector<size_t> &slots) {
    check_cancelled();
    auto rows = decoder.decode(tokens, position, sequence, slots);
    diagnostics.decoded_tokens += tokens.size();
    ++diagnostics.decode_calls;
    check_cancelled();
    if (rows.size() != slots.size())
      throw Error(503, "Missing verdict logit rows");
    return rows;
  };
  if (shared) {
    decode(Tokens(request.prefix.begin(), request.prefix.begin() + shared), 0, 0, {});
    diagnostics.prefix_decoded_tokens = shared;
  }
  Distributions distributions;
  for (const auto &question : request.questions) {
    check_cancelled();
    if (shared) {
      decoder.remove_branch();
      decoder.copy_prefix();
      ++diagnostics.sequence_copies;
      diagnostics.shared_tokens = shared;
    } else {
      decoder.clear();
    }
    Tokens branch(request.prefix.begin() + shared, request.prefix.end());
    branch.insert(branch.end(), question.tokens.begin(), question.tokens.end());
    std::vector<size_t> slots;
    for (size_t slot : question.slots)
      slots.push_back(prefix - shared + slot);
    const auto rows = decode(branch, shared, shared ? 1 : 0, slots);
    distributions.push_back(verdict_probabilities(rows, manifest.temperature));
    if (shared)
      decoder.remove_branch();
  }
  return distributions;
}
} // namespace edge_one
