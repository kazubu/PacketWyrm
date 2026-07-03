#include "packetwyrm/packetwyrm.h"

#define PW_STRINGIFY_(x) #x
#define PW_STRINGIFY(x)  PW_STRINGIFY_(x)

/* Build-time git revision, injected by the Makefile as a string literal
 * (-DPW_GIT_REV='"<short-sha>[+dirty]"'). All SW binaries funnel their version
 * string through here, so this is the single point that carries the revision.
 * Falls back to "unknown" for builds outside a git tree / without the define. */
#ifndef PW_GIT_REV
#define PW_GIT_REV "unknown"
#endif

const char *pw_version_string(void) {
    return PW_STRINGIFY(PACKETWYRM_VERSION_MAJOR) "."
           PW_STRINGIFY(PACKETWYRM_VERSION_MINOR) "."
           PW_STRINGIFY(PACKETWYRM_VERSION_PATCH)
           " (" PW_GIT_REV ")";
}
