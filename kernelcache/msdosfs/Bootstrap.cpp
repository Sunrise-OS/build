#include <mach/mach_types.h>
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>

extern "C" int msdosfs_module_start(kmod_info_t *, void *);

// Vnode operation descriptors are initialized by BSD's vfsinit, after early
// kext startup. Wait for IOBSD rather than registering from the kmod entry.
class MSDOSFSBootstrap : public IOService {
    OSDeclareDefaultStructors(MSDOSFSBootstrap);
public:
    bool start(IOService *provider) override;
};
OSDefineMetaClassAndStructors(MSDOSFSBootstrap, IOService);

bool MSDOSFSBootstrap::start(IOService *provider)
{
    if (!IOService::start(provider)) return false;
    if (msdosfs_module_start(nullptr, nullptr) != KERN_SUCCESS) {
        IOLog("msdosfs: filesystem registration failed\n");
        return false;
    }
    IOLog("msdosfs: registered read-only root filesystem\n");
    registerService();
    return true;
}
