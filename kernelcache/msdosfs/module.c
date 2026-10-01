#include <mach/mach_types.h>
#include <mach/kmod.h>
static kern_return_t msdosfs_start(kmod_info_t *info, void *data) { return KERN_SUCCESS; }
// The registered filesystem is permanent for this emulator boot.
static kern_return_t msdosfs_stop(kmod_info_t *info, void *data) { return KERN_FAILURE; }
KMOD_EXPLICIT_DECL(com.apple.kec.msdosfs, "1.0.0", msdosfs_start, msdosfs_stop)
