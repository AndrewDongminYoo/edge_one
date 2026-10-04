#include "edge_one.h"
#include <stddef.h>

int main(void) {
  int32_t status = 0;
  char *result = eo_evaluate(NULL, "{}", &status);
  eo_free(result);
  eo_cancel(NULL);
  eo_close(NULL);
  return status == EO_STATUS_UNAVAILABLE ? 0 : 1;
}
