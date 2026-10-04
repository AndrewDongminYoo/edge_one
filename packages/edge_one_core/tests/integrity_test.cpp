#include "integrity.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace edge_one;
#define CHECK(condition)                                                                           \
  do {                                                                                             \
    if (!(condition))                                                                              \
      throw std::runtime_error(#condition);                                                        \
  } while (false)

template <class F> void rejected(F operation) {
  try {
    operation();
  } catch (const Error &error) {
    CHECK(error.status == 503);
    return;
  }
  throw std::runtime_error("expected identity/integrity rejection");
}

int main(int argc, char **argv) {
  try {
    CHECK(argc == 3);
    std::ifstream stream(argv[1]);
    const std::string text((std::istreambuf_iterator<char>(stream)), {});
    const auto document = parse_json(text.c_str());
    const auto manifest = parse_manifest(text.c_str());
    validate_pinned_manifest(manifest);
    for (const auto &change :
         std::vector<std::pair<std::string, Json>>{{"/id", "different"},
                                                   {"/revision", std::string(40, 'a')},
                                                   {"/file", "other.gguf"},
                                                   {"/sha256", std::string(64, '0')},
                                                   {"/bytes", manifest.bytes + 1},
                                                   {"/slot_tokens/yes", 9543},
                                                   {"/slot_tokens/no", 875},
                                                   {"/slot_tokens/verdict_slot", 1412},
                                                   {"/temperature/global", 1.0},
                                                   {"/limits/n_ctx", 2049}}) {
      auto modified = document;
      modified[Json::json_pointer(change.first)] = change.second;
      rejected([&] { validate_pinned_manifest(parse_manifest(modified.dump().c_str())); });
    }
    auto reduced = manifest;
    reduced.max_options = 1;
    reduced.max_levels = 2;
    reduced.n_ctx = 1024;
    validate_pinned_manifest(reduced);
    auto raised = manifest;
    raised.max_options = 27;
    rejected([&] { validate_pinned_manifest(raised); });
    raised = manifest;
    raised.max_levels = 11;
    rejected([&] { validate_pinned_manifest(raised); });
    auto mirrors = document;
    mirrors["mirrors"] = Json::array({"https://example.invalid/model"});
    validate_pinned_manifest(parse_manifest(mirrors.dump().c_str()));

    const auto file = std::filesystem::path(argv[2]) / "integrity-vector.bin";
    const std::string digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    {
      std::ofstream output(file, std::ios::binary);
      output << "abc";
    }
    verify_model_file(file.c_str(), digest, 3);
    rejected([&] { verify_model_file(file.c_str(), digest, 4); });
    {
      std::ofstream output(file, std::ios::binary);
      output << "abd";
    }
    rejected([&] { verify_model_file(file.c_str(), digest, 3); });
    rejected([&] { verify_model_file("/does/not/exist", digest, 3); });
    rejected([&] { verify_model_file(nullptr, digest, 3); });
    std::filesystem::remove(file);
    std::cout << "Pinned identity and actual file integrity tests passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
