#include "Benchmark.hpp"
#include <fstream>
#include <filesystem>
#include <iostream>
#include <iterator>
#include <stdexcept>

int main(int argc, char ** argv) {
    try {
        if (argc != 3) throw std::runtime_error("usage: m0-host MODEL FIXTURE");
        std::ifstream input(argv[2]);
        if (!input) throw std::runtime_error("fixture not found");
        const std::string fixture((std::istreambuf_iterator<char>(input)), {});
        auto checksum_path = std::filesystem::path(argv[2]);
        checksum_path.replace_extension(".sha256");
        std::ifstream checksum_file(checksum_path);
        std::string checksum;
        if (!(checksum_file >> checksum)) throw std::runtime_error("fixture checksum not found");
        std::cout << m0_benchmark(argv[1], fixture, checksum, 2) << '\n';
        return 0;
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
