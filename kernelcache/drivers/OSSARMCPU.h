#ifndef _OSSARMCPU_H
#define _OSSARMCPU_H

#include <IOKit/IOCPU.h>

class OSSARMCPU : public IOCPU
{
	OSDeclareDefaultStructors(OSSARMCPU);

public:
	void                   configureCPUNumber(UInt32 cpuNumber);

	virtual void           initCPU(bool boot) APPLE_KEXT_OVERRIDE;
	virtual void           quiesceCPU(void) APPLE_KEXT_OVERRIDE;
	virtual kern_return_t  startCPU(vm_offset_t start_paddr,
	    vm_offset_t arg_paddr) APPLE_KEXT_OVERRIDE;
	virtual void           haltCPU(void) APPLE_KEXT_OVERRIDE;
	virtual const OSSymbol *getCPUName(void) APPLE_KEXT_OVERRIDE;
};

#endif /* _OSSARMCPU_H */
