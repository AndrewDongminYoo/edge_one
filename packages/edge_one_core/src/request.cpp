#include "core.hpp"

#include <cmath>
#include <initializer_list>
#include <limits>
#include <set>

namespace edge_one {
namespace {
[[noreturn]] void invalid(const std::string &message) { throw Error(422, message); }

bool structured(const Json &value, bool optional = false) {
  return value.is_string() || value.is_object() || value.is_array() ||
         (optional && value.is_null());
}

void fields(const Json &value, std::initializer_list<const char *> allowed,
            std::initializer_list<const char *> required) {
  if (!value.is_object())
    invalid("Expected a JSON object");
  for (const auto &field : required) {
    if (!value.contains(field))
      invalid(std::string("Missing field: ") + field);
  }
  const std::set<std::string> names(allowed.begin(), allowed.end());
  for (const auto &item : value.items()) {
    if (names.count(item.key()) == 0)
      invalid("Unknown field: " + item.key());
  }
}

int32_t positive_int(const Json &object, const char *key, int32_t maximum) {
  if (!object.is_object() || !object.contains(key))
    invalid(std::string("Missing ") + key);
  const auto &value = object.at(key);
  if (!value.is_number_integer() || value < 1 || value > maximum)
    invalid(std::string("Invalid positive integer: ") + key);
  return value.get<int32_t>();
}

std::string nonempty(const Json &object, const char *key) {
  if (!object.is_object() || !object.contains(key) || !object.at(key).is_string() ||
      object.at(key).get_ref<const std::string &>().empty())
    invalid(std::string("Expected nonempty string: ") + key);
  return object.at(key).get<std::string>();
}
} // namespace

Json parse_json(const char *text) {
  if (!text)
    invalid("JSON input is null");
  constexpr size_t max_bytes = 4 * 1024 * 1024;
  size_t length = 0;
  while (length <= max_bytes && text[length] != '\0')
    ++length;
  if (length > max_bytes)
    invalid("JSON input exceeds 4 MiB");
  std::vector<std::set<std::string>> object_keys;
  auto callback = [&](int depth, Json::parse_event_t event, Json &value) {
    if (depth > 128)
      invalid("JSON nesting exceeds 128 levels");
    if (event == Json::parse_event_t::object_start)
      object_keys.emplace_back();
    if (event == Json::parse_event_t::key &&
        !object_keys.back().insert(value.get<std::string>()).second)
      invalid("Duplicate JSON object key");
    if (event == Json::parse_event_t::object_end)
      object_keys.pop_back();
    return true;
  };
  try {
    return Json::parse(text, text + length, callback);
  } catch (const Json::exception &) {
    invalid("Malformed JSON or UTF-8");
  }
}

Manifest parse_manifest(const char *text) {
  const auto value = parse_json(text);
  if (nonempty(value, "template") != "macjev-render-v1" || nonempty(value, "readout") != "verdict")
    invalid("Unsupported model template or readout");
  const auto id = nonempty(value, "id");
  const auto revision = nonempty(value, "revision");
  const auto file = nonempty(value, "file");
  const auto sha256 = nonempty(value, "sha256");
  if (sha256.size() != 64 || sha256.find_first_not_of("0123456789abcdef") != std::string::npos)
    invalid("Invalid model SHA-256");
  if (!value.contains("bytes") || !value.at("bytes").is_number_integer() || value.at("bytes") < 1)
    invalid("Invalid model byte count");
  const auto bytes = value.at("bytes").get<uint64_t>();
  if (!value.contains("limits") || !value.contains("slot_tokens") || !value.contains("temperature"))
    invalid("Missing manifest runtime configuration");
  const auto &limits = value.at("limits");
  const auto &slots = value.at("slot_tokens");
  const auto &temperatures = value.at("temperature");
  if (!temperatures.is_object() || !temperatures.contains("global") ||
      !temperatures.at("global").is_number())
    invalid("Invalid global temperature");
  const auto temperature = temperatures.at("global").get<double>();
  if (!std::isfinite(temperature) || temperature <= 0)
    invalid("Invalid global temperature");
  Manifest result{id,
                  revision,
                  file,
                  sha256,
                  bytes,
                  positive_int(limits, "max_options", 26),
                  positive_int(limits, "max_levels", 10),
                  positive_int(limits, "n_ctx", 25600),
                  positive_int(slots, "yes", std::numeric_limits<int32_t>::max()),
                  positive_int(slots, "no", std::numeric_limits<int32_t>::max()),
                  positive_int(slots, "verdict_slot", std::numeric_limits<int32_t>::max()),
                  temperature};
  if (result.max_levels < 2)
    invalid("Score requires at least two levels");
  if (result.yes == result.no || result.yes == result.verdict || result.no == result.verdict)
    invalid("Readout token IDs must differ");
  return result;
}

void validate_request(const Json &request, const Manifest &manifest) {
  fields(request, {"state", "model", "questions"}, {"state", "model", "questions"});
  if (!structured(request.at("state")))
    invalid("Invalid state");
  if (!request.at("model").is_string())
    invalid("Expected model string");
  const auto &questions = request.at("questions");
  if (!questions.is_object() || questions.empty())
    invalid("Expected at least one question");
  for (const auto &question : questions) {
    fields(question, {"type", "instructions", "criteria"}, {"type"});
    if (!question.at("type").is_string())
      invalid("Expected question type");
    if (question.contains("instructions") && !structured(question.at("instructions"), true))
      invalid("Invalid instructions");
    const auto type = question.at("type").get<std::string>();
    const auto criteria = question.value("criteria", Json());
    if (type == "choice") {
      if (!criteria.is_object() || criteria.empty() ||
          criteria.size() > static_cast<size_t>(manifest.max_options))
        invalid("Choice option count exceeds local limits");
      for (const auto &description : criteria)
        if (!structured(description, true))
          invalid("Invalid Choice description");
    } else if (type == "score") {
      if (!criteria.is_array() || criteria.size() < 2 ||
          criteria.size() > static_cast<size_t>(manifest.max_levels))
        invalid("Score level count exceeds local limits");
      for (const auto &description : criteria)
        if (!structured(description))
          invalid("Invalid Score description");
    } else if (type == "noul") {
      if (!criteria.is_null()) {
        fields(criteria, {"false", "true"}, {});
        for (const auto &description : criteria)
          if (!structured(description, true))
            invalid("Invalid Noul description");
      }
    } else {
      invalid("Unknown question type");
    }
  }
}
} // namespace edge_one
