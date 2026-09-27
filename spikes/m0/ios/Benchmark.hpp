#pragma once
#include <string>

// Experimental Apple-only entry point; not the production edge_one API.
std::string m0_benchmark(const std::string & model_path, const std::string & fixture_json,
                         const std::string & fixture_sha256, int repetitions,
                         int sustained_ms = 0, int (*thermal_state)() = nullptr);
