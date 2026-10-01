#include <mach/mach_types.h>
extern "C" {
kern_return_t IOStorageFamily_start(kmod_info_t *, void *) { return KERN_SUCCESS; }
kern_return_t IOStorageFamily_stop(kmod_info_t *, void *) { return KERN_SUCCESS; }
KMOD_EXPLICIT_DECL(com.apple.iokit.IOStorageFamily, "2.1", IOStorageFamily_start, IOStorageFamily_stop)
}
