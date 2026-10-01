/*
 * Platform expert for the QEMU "virt" machine as described by q1n1's AFDT.
 *
 * XNU matches an IOPlatformExpert against the device tree root; with nothing
 * matching it falls back to IOPanicPlatform. The generic IODTPlatformExpert does
 * nearly everything (nubs for cpus and top-level children, NVRAM publishing,
 * name/model queries); this subclass only supplies its required lists and the
 * machine identity. Interrupt routing, CPUs and devices are separate drivers.
 */
#include <IOKit/IOPlatformExpert.h>
#include <IOKit/IOLib.h>
#include <kern/debug.h>
#include <mach/mach_types.h>
#include <mach/kmod.h>

class OSSPlatformExpert : public IODTPlatformExpert
{
	OSDeclareDefaultStructors(OSSPlatformExpert);

public:
	virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
	virtual const char *deleteList(void) APPLE_KEXT_OVERRIDE;
	virtual const char *excludeList(void) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(OSSPlatformExpert, IODTPlatformExpert);

bool
OSSPlatformExpert::start(IOService *provider)
{
	if (!IODTPlatformExpert::start(provider)) {
		return false;
	}
	/* Everything below the root that matters is published by processTopLevel(). */
	registerService();
	return true;
}

/* Nodes removed from the IODeviceTree plane before nubs are created: none. */
const char *
OSSPlatformExpert::deleteList(void)
{
	return "";
}

/* Top-level nodes that do not get a nub: chosen/defaults/pram are data, not devices. */
const char *
OSSPlatformExpert::excludeList(void)
{
	return "chosen,defaults,options,pram,memory-map";
}

extern "C" kern_return_t OSSPlatformExpert_start(kmod_info_t *, void *);
extern "C" kern_return_t OSSPlatformExpert_stop(kmod_info_t *, void *);

extern "C" kern_return_t
OSSPlatformExpert_start(kmod_info_t *, void *)
{
	return KERN_SUCCESS;
}

extern "C" kern_return_t
OSSPlatformExpert_stop(kmod_info_t *, void *)
{
	return KERN_FAILURE; /* a platform expert cannot be unloaded */
}

extern "C" {
KMOD_EXPLICIT_DECL(org.opendarwin.driver.OSSPlatformExpert, "1.0.0",
    OSSPlatformExpert_start, OSSPlatformExpert_stop)
}
