#include "model_loader.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <type_traits>
#if defined(__unix__) || defined(__APPLE__)
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#endif

using namespace edge_one;
static_assert(!std::is_move_assignable<VerifiedModel>::value,
              "Replacing an owner must not close its file before freeing its model");
#define CHECK(condition) \
  do { if (!(condition)) throw std::runtime_error(#condition); } while (false)

namespace {
std::filesystem::path model_path;
const std::string digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
FILE *loaded_stream = nullptr;
int loaded_fd = -1;
int model_token;
bool use_null = false;
bool throw_on_load = false;
bool replace_name = true;
bool original_bytes = false;
bool rewind_ok = false;
bool lifetime_ok = false;
bool used_file_loader = false;
bool profile_ok = false;
int free_count = 0;

void write(const std::filesystem::path &path, const std::string &bytes) {
  std::ofstream file(path, std::ios::binary);
  file << bytes;
  CHECK(file.good());
}
void replace() {
  if (!replace_name) return;
  const auto previous = model_path.string() + ".previous";
  std::filesystem::rename(model_path, previous);
  write(model_path, "def");
}
void observe(FILE *file, llama_model_params params) {
  loaded_stream = file;
#if defined(__unix__) || defined(__APPLE__)
  loaded_fd = fileno(file);
#endif
  rewind_ok = std::ftell(file) == 0 && !std::feof(file) && !std::ferror(file);
  char bytes[3];
  original_bytes = std::fread(bytes, 1, sizeof(bytes), file) == sizeof(bytes) &&
                   std::string(bytes, sizeof(bytes)) == "abc";
  profile_ok = params.load_mode == LLAMA_LOAD_MODE_MMAP && params.n_gpu_layers == 0;
}
void closed() {
#if defined(__unix__) || defined(__APPLE__)
  errno = 0;
  CHECK(fcntl(loaded_fd, F_GETFD) == -1 && errno == EBADF);
#endif
}
void reset() {
  write(model_path, "abc");
  loaded_stream = nullptr;
  loaded_fd = -1;
  original_bytes = rewind_ok = lifetime_ok = used_file_loader = profile_ok = false;
  use_null = throw_on_load = false;
  replace_name = true;
  free_count = 0;
}
}

// These link-time doubles are compiled only into the model-free boundary test.
// Both entry points exist so reverting production to the pathname loader fails.
llama_model *llama_model_load_from_file(const char *path, llama_model_params params) {
  replace();
  FILE *file = std::fopen(path, "rb");
  CHECK(file);
  observe(file, params);
  std::fclose(file);
  loaded_stream = nullptr;
  return reinterpret_cast<llama_model *>(&model_token);
}
llama_model *llama_model_load_from_file_ptr(FILE *file, llama_model_params params) {
  used_file_loader = true;
  replace();
  observe(file, params);
  if (throw_on_load) throw std::runtime_error("simulated loader exception");
  return use_null ? nullptr : reinterpret_cast<llama_model *>(&model_token);
}
void llama_model_free(llama_model *model) {
  ++free_count;
  if (model != reinterpret_cast<llama_model *>(&model_token) || !loaded_stream) return;
  char bytes[3];
  lifetime_ok = std::fseek(loaded_stream, 0, SEEK_SET) == 0 &&
                std::fread(bytes, 1, sizeof(bytes), loaded_stream) == sizeof(bytes) &&
                std::string(bytes, sizeof(bytes)) == "abc";
}

int main(int argc, char **argv) {
  try {
    CHECK(argc == 2);
    model_path = std::filesystem::path(argv[1]) / "loader-identity.bin";
    llama_model_params params{};
    params.load_mode = LLAMA_LOAD_MODE_MMAP;
    params.n_gpu_layers = 0;
    reset();
    {
      VerifiedModel model(model_path.string().c_str(), digest, 3, params);
      CHECK(model.get() == reinterpret_cast<llama_model *>(&model_token));
      CHECK(original_bytes);
      CHECK(used_file_loader);
      CHECK(rewind_ok);
      CHECK(profile_ok);
      CHECK(free_count == 0);
    }
    CHECK(free_count == 1 && lifetime_ok);
    closed();
    for (bool throws : {false, true}) {
      reset();
      use_null = !throws;
      throw_on_load = throws;
      bool rejected = false;
      try { VerifiedModel model(model_path.string().c_str(), digest, 3, params); }
      catch (const std::exception &) { rejected = true; }
      CHECK(rejected && used_file_loader && original_bytes && rewind_ok && free_count == 0);
      closed();
    }
    reset();
    replace_name = false;
    write(model_path, "abd");
    bool rejected = false;
    try { VerifiedModel model(model_path.string().c_str(), digest, 3, params); }
    catch (const Error &error) { rejected = error.status == 503; }
    CHECK(rejected && !used_file_loader && loaded_stream == nullptr && free_count == 0);
    std::filesystem::remove(model_path);
    std::filesystem::remove(model_path.string() + ".previous");
    std::cout << "Verified FILE loader identity, rewind, profile and lifetime passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
