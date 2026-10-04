#include "core.hpp"

#include <utility>

namespace edge_one {
namespace {
// JSON escaping keeps nested structure intact while preventing literal model
// controls. Plain text also escapes line boundaries used by the prompt template.
std::string escape_angles(const std::string &text) {
  std::string result;
  for (char byte : text) {
    if (byte == '<')
      result += "\\u003c";
    else if (byte == '>')
      result += "\\u003e";
    else
      result += byte;
  }
  return result;
}

std::string json_text(const Json &value) {
  if (value.is_object()) {
    std::string result = "{";
    for (const auto &entry : value.items()) {
      if (result.size() > 1)
        result += ", ";
      result += escape_angles(Json(entry.key()).dump()) + ": " + json_text(entry.value());
    }
    return result + "}";
  }
  if (value.is_array()) {
    std::string result = "[";
    for (const auto &entry : value) {
      if (result.size() > 1)
        result += ", ";
      result += json_text(entry);
    }
    return result + "]";
  }
  return escape_angles(value.dump());
}

std::string text(const Json &value) {
  if (value.is_null())
    return "";
  if (!value.is_string())
    return json_text(value);
  // Quotes have no delimiter meaning in plain text. Preserve ordinary prose;
  // escape only controls, backslashes and angle brackets.
  const auto &plain = value.get_ref<const std::string &>();
  std::string result;
  for (char byte : plain) {
    if (byte == '<')
      result += "\\u003c";
    else if (byte == '>')
      result += "\\u003e";
    else if (byte == '\\')
      result += "\\\\";
    else if (static_cast<unsigned char>(byte) < 0x20) {
      const auto escaped = Json(std::string(1, byte)).dump();
      result += escaped.substr(1, escaped.size() - 2);
    } else
      result += byte;
  }
  return result;
}

void append(Tokens &destination, const Tokens &source) {
  destination.insert(destination.end(), source.begin(), source.end());
}
} // namespace

RenderedRequest render_request(const Json &request, const Manifest &manifest,
                               const Encoder &encode) {
  validate_request(request, manifest);
  RenderedRequest result;
  result.model = request.at("model").get<std::string>();
  const auto budget = static_cast<size_t>(manifest.n_ctx);
  auto count = [&](size_t size) {
    if (size > budget - result.input_tokens)
      throw Error(422, "Rendered input exceeds token budget");
    result.input_tokens += size;
  };
  auto encode_prefix = [&](const std::string &piece) {
    const auto ids = encode(piece);
    count(ids.size());
    append(result.prefix, ids);
  };
  encode_prefix("State:\n");
  encode_prefix(text(request.at("state")));
  encode_prefix("\n\n");
  for (const auto &entry : request.at("questions").items()) {
    const auto &source = entry.value();
    RenderedQuestion question;
    question.key = entry.key();
    question.type = source.at("type").get<std::string>();
    question.criteria = source.value("criteria", Json());
    std::vector<std::string> options;
    if (question.type == "choice") {
      for (const auto &option : question.criteria.items()) {
        question.names.push_back(option.key());
        const auto description = text(option.value());
        options.push_back(text(Json(option.key())) +
                          (description.empty() ? "" : ": " + description));
      }
    } else if (question.type == "score") {
      for (size_t i = 0; i < question.criteria.size(); ++i) {
        question.names.push_back(std::to_string(i));
        options.push_back("level " + std::to_string(i) + ": " + text(question.criteria[i]));
      }
    } else {
      question.names = {"false", "true"};
      for (const auto &name : question.names) {
        const auto description =
            question.criteria.is_object() ? text(question.criteria.value(name, Json())) : "";
        options.push_back(name + ": " +
                          (description.empty()
                               ? (name == "false" ? "no, the statement does not hold"
                                                  : "yes, the statement holds")
                               : description));
      }
    }
    auto add = [&](const Tokens &ids) {
      count(ids.size());
      append(question.tokens, ids);
    };
    add(encode("Question [" + question.type + "]: " + text(source.value("instructions", Json())) +
               "\nOptions:\n"));
    std::vector<Tokens> encoded_options;
    for (const auto &option : options) {
      encoded_options.push_back(encode(option));
      add(encode("- "));
      add(encoded_options.back());
      add(encode("\n"));
    }
    add(encode("Judge each option:\n"));
    for (const auto &option : encoded_options) {
      add(option);
      add(Tokens{manifest.verdict});
      question.slots.push_back(question.tokens.size() - 1);
      add(encode("\n"));
    }
    result.questions.push_back(std::move(question));
  }
  return result;
}
} // namespace edge_one
