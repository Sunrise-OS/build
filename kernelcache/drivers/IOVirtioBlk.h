#ifndef _IOVIRTIOBLK_H
#define _IOVIRTIOBLK_H

#include <IOKit/storage/IOBlockStorageDevice.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOLocks.h>

class IOVirtioBlk : public IOBlockStorageDevice
{
	OSDeclareDefaultStructors(IOVirtioBlk);

public:
	virtual bool init(OSDictionary * properties = NULL) APPLE_KEXT_OVERRIDE;
	virtual bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
	virtual void stop(IOService * provider) APPLE_KEXT_OVERRIDE;
	virtual void free(void) APPLE_KEXT_OVERRIDE;

	virtual IOReturn doAsyncReadWrite(IOMemoryDescriptor * buffer,
	    UInt64 block, UInt64 nblks,
	    IOStorageAttributes * attributes,
	    IOStorageCompletion * completion) APPLE_KEXT_OVERRIDE;

	virtual IOReturn doEjectMedia(void) APPLE_KEXT_OVERRIDE;
	virtual IOReturn doFormatMedia(UInt64 byteCapacity) APPLE_KEXT_OVERRIDE;
	virtual UInt32 doGetFormatCapacities(UInt64 * capacities,
	    UInt32 capacitiesMaxCount) const APPLE_KEXT_OVERRIDE;

	virtual char * getVendorString(void) APPLE_KEXT_OVERRIDE;
	virtual char * getProductString(void) APPLE_KEXT_OVERRIDE;
	virtual char * getRevisionString(void) APPLE_KEXT_OVERRIDE;
	virtual char * getAdditionalDeviceInfoString(void) APPLE_KEXT_OVERRIDE;

	virtual IOReturn reportBlockSize(UInt64 * blockSize) APPLE_KEXT_OVERRIDE;
	virtual IOReturn reportEjectability(bool * isEjectable) APPLE_KEXT_OVERRIDE;
	virtual IOReturn reportMaxValidBlock(UInt64 * maxBlock) APPLE_KEXT_OVERRIDE;
	virtual IOReturn reportMediaState(bool * mediaPresent, bool * changedState) APPLE_KEXT_OVERRIDE;
	virtual IOReturn reportRemovability(bool * isRemovable) APPLE_KEXT_OVERRIDE;
	virtual IOReturn reportWriteProtection(bool * isWriteProtected) APPLE_KEXT_OVERRIDE;

private:
	bool probeAndInit(void);
	bool setupQueue(void);
	IOReturn readBlocks(UInt64 startBlock, UInt64 nblks, void * buf);
	uint32_t mmioRead(uint32_t off);
	void mmioWrite(uint32_t off, uint32_t val);
	void releaseHw(void);

	IOMemoryDescriptor * _regDesc;
	IOMemoryMap * _regMap;
	IOVirtualAddress _regBase;

	IOBufferMemoryDescriptor * _vqDesc;
	void * _vqVirt;
	IOPhysicalAddress _vqPhys;
	uint16_t _queueSize;
	uint16_t _availIdx;
	uint16_t _usedIdx;
	uint16_t _nextDesc;

	IOBufferMemoryDescriptor * _hdrDesc;
	IOBufferMemoryDescriptor * _statusDesc;

	IOLock * _lock;
	UInt64 _blockCount;
};

#endif /* _IOVIRTIOBLK_H */
