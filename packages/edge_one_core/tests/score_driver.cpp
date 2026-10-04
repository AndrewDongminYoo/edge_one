#include "scorer.hpp"

#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace edge_one;

int main(int argc, char **argv) {
  try {
    if (argc != 4)
      throw std::runtime_error("usage: edge_one_score_driver MODEL MANIFEST individual|exact");
    const std::string mode(argv[3]);
    if (mode != "individual" && mode != "exact")
      throw std::runtime_error("Unsupported scoring mode");
    std::ifstream input(argv[2]);
    const std::string text((std::istreambuf_iterator<char>(input)), {});
    const auto manifest = parse_manifest(text.c_str());
    ScoreDiagnostics diagnostics;
    Json profile;
    auto backend = open_scoring_backend(
        argv[1], manifest, mode == "individual" ? ScoreMode::individual : ScoreMode::exact,
        &diagnostics, &profile);
    std::cout << Json({{"ready", true},
                       {"profile", profile},
                       {"mode", mode},
                       {"model_sha256", manifest.sha256},
                       {"revision", manifest.revision},
                       {"temperature", manifest.temperature}})
                     .dump()
              << std::endl;
    std::atomic<bool> cancelled{false};
    std::string line;
    while (std::getline(std::cin, line)) {
      const auto start = std::chrono::steady_clock::now();
      const auto request =
          render_request(parse_json(line.c_str()), manifest,
                         [&](const std::string &value) { return backend->encode(value); });
      const auto distributions = backend->score(request, cancelled);
      Json questions = Json::array();
      for (const auto &question : request.questions)
        questions.push_back(
            {{"names", question.names}, {"tokens", question.tokens}, {"slots", question.slots}});
      const double elapsed =
          std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start)
              .count();
      std::cout << Json({{"rendered", {{"prefix", request.prefix}, {"questions", questions}}},
                         {"distributions", distributions},
                         {"response", make_response(request, manifest, distributions)},
                         {"duration_ms", elapsed},
                         {"diagnostics",
                          {{"shared_tokens", diagnostics.shared_tokens},
                           {"prefix_decoded_tokens", diagnostics.prefix_decoded_tokens},
                           {"sequence_copies", diagnostics.sequence_copies},
                           {"decoded_tokens", diagnostics.decoded_tokens},
                           {"decode_calls", diagnostics.decode_calls}}}})
                       .dump()
                << std::endl;
    }
    return 0;
  } catch (const std::exception &error) {
    std::cout << Json({{"error", error.what()}}).dump() << std::endl;
    return 1;
  }
}
