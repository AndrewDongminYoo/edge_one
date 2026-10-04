#include "engine.hpp"

#include <cmath>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace edge_one;
#define CHECK(condition)                                                                           \
  do {                                                                                             \
    if (!(condition))                                                                              \
      throw std::runtime_error(#condition);                                                        \
  } while (false)

int main(int argc, char **argv) {
  try {
    CHECK(argc == 2);
    std::ifstream input(argv[1]);
    const std::string text((std::istreambuf_iterator<char>(input)), {});
    const auto manifest = parse_manifest(text.c_str());
    const auto request = parse_json(R"({"state":{},"model":"m","questions":{
      "c":{"type":"choice","criteria":{"z":null,"a":null,"b":null}},
      "s":{"type":"score","criteria":[{"nested":[1,true]},"medium",["high"]]},
      "n":{"type":"noul"},"only":{"type":"choice","criteria":{"one":null}}
    }})");
    const auto rendered = render_request(
        request, manifest, [](const std::string &value) { return Tokens(value.size(), 1); });
    const Distributions distributions{{0.1, 0.7, 0.2}, {0.1, 0.2, 0.7}, {0.4, 0.6}, {1.0}};
    const auto result = make_response(rendered, manifest, distributions);
    const auto &answers = result.at("answers");
    CHECK(answers.at("c").at("choice") == "a");
    CHECK(std::abs(answers.at("c").at("confidence").get<double>() - 0.55) < 1e-12);
    CHECK(std::abs(answers.at("s").at("score").get<double>() - 1.6) < 1e-12);
    CHECK(answers.at("s").at("legend").at("0") == request["questions"]["s"]["criteria"][0]);
    CHECK(answers.at("s").at("legend").at("2") == Json::array({"high"}));
    CHECK(answers.at("n").at("noul") == 0.6);
    CHECK(!answers.at("n").contains("confidence"));
    CHECK(answers.at("only").at("confidence") == 1.0);
    CHECK(result.at("usage").at("input_tokens") == rendered.input_tokens);
    CHECK(result.at("usage").at("output_tokens") == 0);
    CHECK(result.at("model") == "m");
    CHECK(result.at("x_route") == "local");
    const auto tie = make_response(rendered, manifest, {{0.5, 0.5, 0}, {0, 0, 1}, {1, 0}, {1}});
    CHECK(tie.at("answers").at("c").at("choice") == "z");

    for (auto invalid : std::vector<Distributions>{
             {}, {{1}}, {{0.1, 0.7, 0.2}}, {{0.1, 0.7, 0.2}, {1}, {0.4, 0.6}, {1}}}) {
      bool caught = false;
      try {
        make_response(rendered, manifest, invalid);
      } catch (const Error &error) {
        CHECK(error.status == 500);
        caught = true;
      }
      CHECK(caught);
    }
    for (double invalid : {-1.0, 1.1, std::numeric_limits<double>::infinity(),
                           std::numeric_limits<double>::quiet_NaN(), 0.2}) {
      auto altered = distributions;
      altered[0][0] = invalid;
      bool caught = false;
      try {
        make_response(rendered, manifest, altered);
      } catch (const Error &error) {
        CHECK(error.status == 500);
        caught = true;
      }
      CHECK(caught);
    }
    std::cout << "Typed response mapping and scorer boundary tests passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
