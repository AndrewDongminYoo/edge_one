#include "model_loader.hpp"

namespace edge_one {
VerifiedModel::VerifiedModel(const char *path, const std::string &sha256, uint64_t bytes,
                             llama_model_params params)
    : file_(open_verified_model_file(path, sha256, bytes)) {
  model_.reset(llama_model_load_from_file_ptr(file_.get(), params));
  if (!model_)
    throw Error(503, "Unable to load local GGUF model");
}
} // namespace edge_one
