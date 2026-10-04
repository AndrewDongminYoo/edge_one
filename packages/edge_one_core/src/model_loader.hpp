#pragma once

#include "integrity.hpp"
#include <llama.h>

namespace edge_one {
// Private owner for the verified stream and the model that maps its backing object.
// The caller/store must keep those bytes immutable until this owner is destroyed.
class VerifiedModel {
public:
  VerifiedModel(const char *path, const std::string &sha256, uint64_t bytes,
                llama_model_params params);
  VerifiedModel(const VerifiedModel &) = delete;
  VerifiedModel &operator=(const VerifiedModel &) = delete;
  llama_model *get() const noexcept { return model_.get(); }

private:
  // Reverse member destruction releases the model/mappings before the FILE.
  ModelFile file_;
  std::unique_ptr<llama_model, decltype(&llama_model_free)> model_{nullptr, llama_model_free};
};
} // namespace edge_one
