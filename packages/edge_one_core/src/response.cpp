#include "engine.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace edge_one {
Json make_response(const RenderedRequest &request, const Manifest &manifest,
                   const Distributions &distributions) {
  if (distributions.size() != request.questions.size())
    throw Error(500, "Scorer returned the wrong question count");
  Json answers = Json::object();
  for (size_t q = 0; q < request.questions.size(); ++q) {
    const auto &question = request.questions[q];
    const auto &values = distributions[q];
    if (values.size() != question.names.size() || values.empty())
      throw Error(500, "Scorer returned the wrong option count");
    for (double value : values)
      if (!std::isfinite(value) || value < 0 || value > 1)
        throw Error(500, "Scorer returned an invalid probability");
    if (std::abs(std::accumulate(values.begin(), values.end(), 0.0) - 1.0) > 1e-8)
      throw Error(500, "Scorer probabilities do not sum to one");
    Json answer = {{"type", question.type}};
    if (question.type == "noul") {
      answer["noul"] = values.at(1);
    } else {
      const auto best =
          static_cast<size_t>(std::max_element(values.begin(), values.end()) - values.begin());
      Json probabilities = Json::object();
      for (size_t i = 0; i < values.size(); ++i)
        probabilities[question.names[i]] = values[i];
      if (question.type == "choice") {
        answer["choice"] = question.names[best];
      } else {
        double score = 0;
        Json legend = Json::object();
        for (size_t i = 0; i < values.size(); ++i) {
          score += static_cast<double>(i) * values[i];
          legend[question.names[i]] = question.criteria.at(i);
        }
        answer["score"] = score;
        answer["legend"] = std::move(legend);
      }
      answer["probabilities"] = std::move(probabilities);
      answer["confidence"] =
          values.size() == 1
              ? 1.0
              : std::clamp((static_cast<double>(values.size()) * values[best] - 1.0) /
                               static_cast<double>(values.size() - 1),
                           0.0, 1.0);
    }
    answers[question.key] = std::move(answer);
  }
  return {{"model", request.model},
          {"answers", std::move(answers)},
          {"usage", {{"input_tokens", request.input_tokens}, {"output_tokens", 0}}},
          {"x_route", "local"},
          {"x_engine", {{"id", manifest.id}, {"revision", manifest.revision}}},
          {"x_confidence_source", "normalized_max_probability"}};
}
} // namespace edge_one
