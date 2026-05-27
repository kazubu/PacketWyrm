#include "packetwyrm/packetwyrm.h"

#define PW_STRINGIFY_(x) #x
#define PW_STRINGIFY(x)  PW_STRINGIFY_(x)

const char *pw_version_string(void) {
    return PW_STRINGIFY(PACKETWYRM_VERSION_MAJOR) "."
           PW_STRINGIFY(PACKETWYRM_VERSION_MINOR) "."
           PW_STRINGIFY(PACKETWYRM_VERSION_PATCH);
}
