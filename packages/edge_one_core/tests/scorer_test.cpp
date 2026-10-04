#include "scorer.hpp"

#include <cmath>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <stdexcept>

using namespace edge_one;
#define CHECK(condition)                                                                           \
  do {                                                                                             \
    if (!(condition))                                                                              \
      throw std::runtime_error(#condition);                                                        \
  } while (false)

template <class F> void rejected(int status, F operation) {
  try {
    operation();
  } catch (const Error &error) {
    CHECK(error.status == status);
    return;
  }
  throw std::runtime_error("expected scoring failure");
}

// A deterministic sequence interpreter verifies branch isolation and positions.
// It is a test dependency, not evidence of real-model probability parity.
class SequenceDecoder : public Decoder {
public:
  std::map<int32_t, Tokens> sequences;
  std::vector<size_t> prefix_lengths;
  std::vector<Tokens> completed;
  std::vector<std::vector<size_t>> requested_slots;
  int clears = 0;
  size_t decode_count = 0;
  size_t fail_at = 0;
  size_t cancel_at = 0;
  std::atomic<bool> *cancel_on_decode = nullptr;
  void clear() noexcept override {
    sequences.clear();
    ++clears;
  }
  void remove_branch() override { sequences.erase(1); }
  void copy_prefix() override {
    CHECK(sequences.count(1) == 0);
    sequences[1] = sequences.at(0);
    prefix_lengths.push_back(sequences.at(0).size());
  }
  VerdictRows decode(const Tokens &tokens, size_t position, int32_t sequence,
                     const std::vector<size_t> &slots) override {
    auto &state = sequences[sequence];
    CHECK(position == state.size());
    state.insert(state.end(), tokens.begin(), tokens.end());
    ++decode_count;
    if (decode_count == fail_at)
      throw Error(503, "injected partial decode failure");
    if (cancel_on_decode && decode_count == cancel_at)
      cancel_on_decode->store(true);
    if (slots.empty())
      return {};
    completed.push_back(state);
    requested_slots.push_back(slots);
    VerdictRows rows;
    for (size_t slot : slots) {
      CHECK(tokens.at(slot) == 1411);
      double sum = 0;
      for (size_t i = 0; i <= position + slot; ++i)
        sum += state.at(i) * (i % 3 + 1);
      rows.push_back({sum / 10000, -sum / 10000});
    }
    return rows;
  }
};

static RenderedRequest request(size_t prefix_size) {
  RenderedRequest result;
  result.prefix = Tokens(prefix_size, 3);
  for (int q = 0; q < 2; ++q) {
    RenderedQuestion question;
    question.key = std::to_string(q);
    question.type = "choice";
    question.names = {"a", "b"};
    question.tokens = {5 + q, 1411, 8 + q, 9, 1411, 10};
    question.slots = {1, 4};
    result.questions.push_back(question);
  }
  result.input_tokens = prefix_size + 12;
  return result;
}

int main(int argc, char **argv) {
  try {
    CHECK(argc == 2);
    std::ifstream stream(argv[1]);
    const std::string text((std::istreambuf_iterator<char>(stream)), {});
    const auto manifest = parse_manifest(text.c_str());
    const auto known = verdict_probabilities({{2, 0}, {0, 0}, {-2, 0}}, 2);
    CHECK(known.size() == 3);
    CHECK(std::abs(known[0] - 0.6652409557748218) < 1e-12);
    CHECK(std::abs(known[1] - 0.24472847105479764) < 1e-12);
    CHECK(verdict_probabilities({{2, 1}}, manifest.temperature) == std::vector<double>{1});
    CHECK(verdict_probabilities({{1e300, 0}, {-1e300, 0}}, 1) == std::vector<double>({1, 0}));
    CHECK(verdict_probabilities({{0, 0}, {0, 0}}, 1) == std::vector<double>({0.5, 0.5}));
    rejected(503, [&] { verdict_probabilities({}, 1); });
    for (double bad : {0.0, -1.0, std::numeric_limits<double>::infinity(),
                       std::numeric_limits<double>::quiet_NaN()})
      rejected(503, [&] { verdict_probabilities({{0, 0}}, bad); });
    rejected(503,
             [&] { verdict_probabilities({{std::numeric_limits<double>::infinity(), 0}}, 1); });
    rejected(503,
             [&] { verdict_probabilities({{0, std::numeric_limits<double>::quiet_NaN()}}, 1); });

    std::atomic<bool> cancelled{false};
    for (size_t prefix : {0, 47, 1023, 1024, 1025}) {
      const auto rendered = request(prefix);
      SequenceDecoder exact, individual;
      ScoreDiagnostics trace, reference_trace;
      const auto actual =
          score_request(exact, rendered, manifest, 1024, ScoreMode::exact, cancelled, trace);
      const auto reference = score_request(individual, rendered, manifest, 1024,
                                           ScoreMode::individual, cancelled, reference_trace);
      CHECK(actual == reference);
      CHECK(exact.completed == individual.completed);
      CHECK(exact.sequences.empty() && individual.sequences.empty());
      CHECK(exact.clears >= 2 && individual.clears >= 3);
      const size_t shared = prefix >= 1024 ? 1024 : 0;
      CHECK(trace.shared_tokens == shared && trace.prefix_decoded_tokens == shared);
      CHECK(trace.sequence_copies == (shared ? 2 : 0));
      CHECK(reference_trace.shared_tokens == 0 && reference_trace.sequence_copies == 0);
      CHECK(trace.decoded_tokens == shared + 2 * (prefix - shared + 6));
      CHECK(trace.decode_calls == (shared ? 3 : 2));
      for (auto length : exact.prefix_lengths)
        CHECK(length == shared);
      for (const auto &slots : exact.requested_slots)
        CHECK(slots == std::vector<size_t>({prefix - shared + 1, prefix - shared + 4}));
    }
    auto rendered = request(1025);
    rendered.questions.resize(1);
    rendered.input_tokens -= 6;
    SequenceDecoder decoder;
    ScoreDiagnostics trace;
    score_request(decoder, rendered, manifest, 1024, ScoreMode::exact, cancelled, trace);
    CHECK(trace.shared_tokens == 0 && trace.sequence_copies == 0 && trace.decode_calls == 1);
    rendered = request(1025);
    for (size_t stage : {1, 2, 3}) {
      SequenceDecoder faulty;
      faulty.fail_at = stage;
      rejected(503, [&] {
        score_request(faulty, rendered, manifest, 1024, ScoreMode::exact, cancelled, trace);
      });
      CHECK(faulty.sequences.empty());
      CHECK(trace.sequence_copies == stage - 1);
      faulty.fail_at = 0;
      CHECK(score_request(faulty, rendered, manifest, 1024, ScoreMode::exact, cancelled, trace)
                .size() == 2);
      CHECK(faulty.sequences.empty());
      faulty.decode_count = 0;
      faulty.cancel_at = stage;
      faulty.cancel_on_decode = &cancelled;
      rejected(499, [&] {
        score_request(faulty, rendered, manifest, 1024, ScoreMode::exact, cancelled, trace);
      });
      CHECK(faulty.sequences.empty());
      CHECK(trace.sequence_copies == stage - 1);
      faulty.cancel_on_decode = nullptr;
      cancelled.store(false);
      CHECK(score_request(faulty, rendered, manifest, 1024, ScoreMode::exact, cancelled, trace)
                .size() == 2);
    }
    score_request(decoder, request(600), manifest, 512, ScoreMode::exact, cancelled, trace);
    CHECK(trace.shared_tokens == 512);
    rendered.questions[0].slots[0] = rendered.questions[0].tokens.size();
    rejected(422, [&] {
      score_request(decoder, rendered, manifest, 1024, ScoreMode::exact, cancelled, trace);
    });
    std::cout << "Verdict readout, exact scheduling and state cleanup tests passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
