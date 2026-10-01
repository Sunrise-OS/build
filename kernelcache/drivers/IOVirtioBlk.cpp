#include <mach/mach_types.h>
#include "IOVirtioBlk.h"

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOMapTypes.h>
#include <IOKit/IOTypes.h>
#include <libkern/OSAtomic.h>
#include <libkern/OSByteOrder.h>

#define super IOBlockStorageDevice
OSDefineMetaClassAndStructors(IOVirtioBlk, IOBlockStorageDevice);

#define kVirtioBlkBlockSize 512ULL

#define VIRTIO_MMIO_BASE   0x0a000000ULL
#define VIRTIO_MMIO_STRIDE 0x200ULL
#define VIRTIO_MMIO_COUNT  32
#define VIRTIO_MMIO_SIZE   0x200ULL

#define VIRTIO_MMIO_MAGIC_VALUE          0x000
#define VIRTIO_MMIO_VERSION              0x004
#define VIRTIO_MMIO_DEVICE_ID            0x008
#define VIRTIO_MMIO_DEVICE_FEATURES      0x010
#define VIRTIO_MMIO_DEVICE_FEATURES_SEL  0x014
#define VIRTIO_MMIO_DRIVER_FEATURES      0x020
#define VIRTIO_MMIO_DRIVER_FEATURES_SEL  0x024
#define VIRTIO_MMIO_QUEUE_SEL            0x030
#define VIRTIO_MMIO_QUEUE_NUM_MAX        0x034
#define VIRTIO_MMIO_QUEUE_NUM            0x038
#define VIRTIO_MMIO_QUEUE_READY          0x044
#define VIRTIO_MMIO_QUEUE_NOTIFY         0x050
#define VIRTIO_MMIO_INTERRUPT_STATUS     0x060
#define VIRTIO_MMIO_INTERRUPT_ACK        0x064
#define VIRTIO_MMIO_STATUS               0x070
#define VIRTIO_MMIO_QUEUE_DESC_LOW       0x080
#define VIRTIO_MMIO_QUEUE_DESC_HIGH      0x084
#define VIRTIO_MMIO_QUEUE_DRIVER_LOW     0x090
#define VIRTIO_MMIO_QUEUE_DRIVER_HIGH    0x094
#define VIRTIO_MMIO_QUEUE_DEVICE_LOW     0x0a0
#define VIRTIO_MMIO_QUEUE_DEVICE_HIGH    0x0a4
#define VIRTIO_MMIO_CONFIG               0x100

#define VIRTIO_MAGIC            0x74726976U
#define VIRTIO_VERSION          2
#define VIRTIO_ID_BLOCK         2

#define VIRTIO_STATUS_ACKNOWLEDGE  1
#define VIRTIO_STATUS_DRIVER       2
#define VIRTIO_STATUS_DRIVER_OK    4
#define VIRTIO_STATUS_FEATURES_OK  8
#define VIRTIO_STATUS_FAILED       128

#define VIRTIO_F_VERSION_1         32
#define VIRTQ_DESC_F_NEXT          1
#define VIRTQ_DESC_F_WRITE         2
#define VIRTIO_BLK_T_IN            0

struct virtq_desc {
	uint64_t addr;
	uint32_t len;
	uint16_t flags;
	uint16_t next;
};

struct virtio_blk_req {
	uint32_t type;
	uint32_t reserved;
	uint64_t sector;
};

static inline uint32_t
align_up(uint32_t v, uint32_t a)
{
	return (v + a - 1) & ~(a - 1);
}

uint32_t
IOVirtioBlk::mmioRead(uint32_t off)
{
	return *(volatile uint32_t *)(_regBase + off);
}

void
IOVirtioBlk::mmioWrite(uint32_t off, uint32_t val)
{
	*(volatile uint32_t *)(_regBase + off) = val;
	OSSynchronizeIO();
}

void
IOVirtioBlk::releaseHw(void)
{
	/* Stop DMA before releasing queue and request memory. */
	if (_regBase) {
		mmioWrite(VIRTIO_MMIO_STATUS, 0);
	}
	if (_hdrDesc) {
		_hdrDesc->complete();
		_hdrDesc->release();
		_hdrDesc = NULL;
	}
	if (_statusDesc) {
		_statusDesc->complete();
		_statusDesc->release();
		_statusDesc = NULL;
	}
	if (_vqDesc) {
		_vqDesc->complete();
		_vqDesc->release();
		_vqDesc = NULL;
		_vqVirt = NULL;
	}
	if (_regMap) {
		_regMap->release();
		_regMap = NULL;
		_regBase = 0;
	}
	if (_regDesc) {
		_regDesc->release();
		_regDesc = NULL;
	}
}

bool
IOVirtioBlk::init(OSDictionary * properties)
{
	if (!super::init(properties)) {
		return false;
	}
	_regDesc = NULL;
	_regMap = NULL;
	_regBase = 0;
	_vqDesc = NULL;
	_vqVirt = NULL;
	_vqPhys = 0;
	_queueSize = 0;
	_availIdx = 0;
	_usedIdx = 0;
	_nextDesc = 0;
	_hdrDesc = NULL;
	_statusDesc = NULL;
	_lock = NULL;
	_blockCount = 0;
	return true;
}

bool
IOVirtioBlk::probeAndInit(void)
{
	for (uint32_t i = 0; i < VIRTIO_MMIO_COUNT; i++) {
		const mach_vm_address_t phys = VIRTIO_MMIO_BASE + (mach_vm_address_t)i * VIRTIO_MMIO_STRIDE;

		IOMemoryDescriptor * desc = IOMemoryDescriptor::withAddressRange(
			phys, VIRTIO_MMIO_SIZE, kIODirectionInOut, NULL);
		if (!desc) {
			continue;
		}
		IOMemoryMap * map = desc->map(kIOMapInhibitCache);
		if (!map) {
			desc->release();
			continue;
		}

		_regDesc = desc;
		_regMap = map;
		_regBase = map->getVirtualAddress();

		if (mmioRead(VIRTIO_MMIO_MAGIC_VALUE) == VIRTIO_MAGIC &&
		    mmioRead(VIRTIO_MMIO_VERSION) == VIRTIO_VERSION &&
		    mmioRead(VIRTIO_MMIO_DEVICE_ID) == VIRTIO_ID_BLOCK) {
			IOLog("IOVirtioBlk: found virtio-blk at 0x%llx\n", phys);
			return true;
		}

		_regMap->release();
		_regDesc->release();
		_regMap = NULL;
		_regDesc = NULL;
		_regBase = 0;
	}
	return false;
}

bool
IOVirtioBlk::setupQueue(void)
{
	mmioWrite(VIRTIO_MMIO_STATUS, 0);
	mmioWrite(VIRTIO_MMIO_STATUS, VIRTIO_STATUS_ACKNOWLEDGE);
	mmioWrite(VIRTIO_MMIO_STATUS,
	    VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER);

	mmioWrite(VIRTIO_MMIO_DEVICE_FEATURES_SEL, 1);
	uint32_t hi = mmioRead(VIRTIO_MMIO_DEVICE_FEATURES);
	if ((hi & (1U << (VIRTIO_F_VERSION_1 - 32))) == 0) {
		IOLog("IOVirtioBlk: device missing VIRTIO_F_VERSION_1\n");
		return false;
	}
	mmioWrite(VIRTIO_MMIO_DRIVER_FEATURES_SEL, 0);
	mmioWrite(VIRTIO_MMIO_DRIVER_FEATURES, 0);
	mmioWrite(VIRTIO_MMIO_DRIVER_FEATURES_SEL, 1);
	mmioWrite(VIRTIO_MMIO_DRIVER_FEATURES, 1U << (VIRTIO_F_VERSION_1 - 32));

	uint32_t status = mmioRead(VIRTIO_MMIO_STATUS);
	mmioWrite(VIRTIO_MMIO_STATUS, status | VIRTIO_STATUS_FEATURES_OK);
	if ((mmioRead(VIRTIO_MMIO_STATUS) & VIRTIO_STATUS_FEATURES_OK) == 0) {
		IOLog("IOVirtioBlk: FEATURES_OK rejected\n");
		return false;
	}

	mmioWrite(VIRTIO_MMIO_QUEUE_SEL, 0);
	uint32_t qmax = mmioRead(VIRTIO_MMIO_QUEUE_NUM_MAX);
	if (qmax < 3) {
		return false;
	}
	_queueSize = (uint16_t)((qmax < 128) ? qmax : 128);
	mmioWrite(VIRTIO_MMIO_QUEUE_NUM, _queueSize);

	const uint32_t descBytes = (uint32_t)sizeof(struct virtq_desc) * _queueSize;
	const uint32_t availBytes = align_up(6 + 2 * _queueSize, 2);
	const uint32_t usedBytes = align_up(6 + 8 * _queueSize, 4);
	const uint32_t availOff = align_up(descBytes, 2);
	const uint32_t usedOff = align_up(availOff + availBytes, 4);
	const uint32_t total = align_up(usedOff + usedBytes, (uint32_t)PAGE_SIZE);

	_vqDesc = IOBufferMemoryDescriptor::inTaskWithOptions(
		kernel_task,
		kIODirectionInOut | kIOMemoryPhysicallyContiguous,
		total, PAGE_SIZE);
	if (!_vqDesc) {
		return false;
	}
	if (_vqDesc->prepare(kIODirectionInOut) != kIOReturnSuccess) {
		return false;
	}
	_vqVirt = _vqDesc->getBytesNoCopy();
	_vqPhys = _vqDesc->getPhysicalAddress();
	bzero(_vqVirt, total);
	/* This bring-up driver polls completions; suppress queue interrupts. */
	*(uint16_t *)((uint8_t *)_vqVirt + availOff) = 1;

	const uint64_t descPhys = (uint64_t)_vqPhys;
	const uint64_t availPhys = descPhys + availOff;
	const uint64_t usedPhys = descPhys + usedOff;

	mmioWrite(VIRTIO_MMIO_QUEUE_DESC_LOW, (uint32_t)descPhys);
	mmioWrite(VIRTIO_MMIO_QUEUE_DESC_HIGH, (uint32_t)(descPhys >> 32));
	mmioWrite(VIRTIO_MMIO_QUEUE_DRIVER_LOW, (uint32_t)availPhys);
	mmioWrite(VIRTIO_MMIO_QUEUE_DRIVER_HIGH, (uint32_t)(availPhys >> 32));
	mmioWrite(VIRTIO_MMIO_QUEUE_DEVICE_LOW, (uint32_t)usedPhys);
	mmioWrite(VIRTIO_MMIO_QUEUE_DEVICE_HIGH, (uint32_t)(usedPhys >> 32));
	mmioWrite(VIRTIO_MMIO_QUEUE_READY, 1);

	_hdrDesc = IOBufferMemoryDescriptor::inTaskWithOptions(
		kernel_task,
		kIODirectionOut | kIOMemoryPhysicallyContiguous,
		sizeof(struct virtio_blk_req), PAGE_SIZE);
	_statusDesc = IOBufferMemoryDescriptor::inTaskWithOptions(
		kernel_task,
		kIODirectionIn | kIOMemoryPhysicallyContiguous,
		1, PAGE_SIZE);
	if (!_hdrDesc || !_statusDesc) {
		return false;
	}
	if (_hdrDesc->prepare(kIODirectionOut) != kIOReturnSuccess) {
		return false;
	}
	if (_statusDesc->prepare(kIODirectionIn) != kIOReturnSuccess) {
		return false;
	}

	status = mmioRead(VIRTIO_MMIO_STATUS);
	mmioWrite(VIRTIO_MMIO_STATUS, status | VIRTIO_STATUS_DRIVER_OK);

	/* virtio-blk config: capacity in 512-byte sectors, little-endian. */
	uint32_t capLo = mmioRead(VIRTIO_MMIO_CONFIG);
	uint32_t capHi = mmioRead(VIRTIO_MMIO_CONFIG + 4);
	_blockCount = ((UInt64)capHi << 32) | capLo;
	_availIdx = 0;
	_usedIdx = 0;
	_nextDesc = 0;
	return _blockCount > 0;
}

bool
IOVirtioBlk::start(IOService * provider)
{
	if (!super::start(provider)) {
		return false;
	}

	_lock = IOLockAlloc();
	if (!_lock) {
		return false;
	}

	if (!probeAndInit() || !setupQueue()) {
		IOLog("IOVirtioBlk: no virtio-blk device found\n");
		return false;
	}

	IOLog("IOVirtioBlk: %llu blocks (%llu bytes)\n",
	    _blockCount, _blockCount * kVirtioBlkBlockSize);
	/* Exercise the queue before publishing media, not merely config-space
	 * capacity. The header word is a useful filesystem bring-up diagnostic. */
	uint8_t firstSector[512];
	if (readBlocks(0, 1, firstSector) != kIOReturnSuccess) {
		IOLog("IOVirtioBlk: initial sector read failed\n");
		releaseHw();
		return false;
	}
	IOLog("IOVirtioBlk: sector 0 header[32] = 0x%08x\n",
	    OSReadLittleInt32(firstSector, 32));

	setProperty("device-type", "Generic");
	registerService();
	return true;
}

void
IOVirtioBlk::stop(IOService * provider)
{
	releaseHw();
	super::stop(provider);
}

void
IOVirtioBlk::free(void)
{
	releaseHw();
	if (_lock) {
		IOLockFree(_lock);
		_lock = NULL;
	}
	super::free();
}

IOReturn
IOVirtioBlk::readBlocks(UInt64 startBlock, UInt64 nblks, void * buf)
{
	if (nblks == 0 || nblks > 128 ||
	    !(mmioRead(VIRTIO_MMIO_STATUS) & VIRTIO_STATUS_DRIVER_OK)) {
		return kIOReturnBadArgument;
	}
	const UInt64 byteCount = nblks * kVirtioBlkBlockSize;
	IOBufferMemoryDescriptor * dataDesc = IOBufferMemoryDescriptor::inTaskWithOptions(
		kernel_task,
		kIODirectionIn | kIOMemoryPhysicallyContiguous,
		(vm_size_t)byteCount, PAGE_SIZE);
	if (!dataDesc) {
		return kIOReturnNoMemory;
	}
	if (dataDesc->prepare(kIODirectionIn) != kIOReturnSuccess) {
		dataDesc->release();
		return kIOReturnNoMemory;
	}

	const uint32_t descBytes = (uint32_t)sizeof(struct virtq_desc) * _queueSize;
	const uint32_t availOff = align_up(descBytes, 2);
	const uint32_t availBytes = align_up(6 + 2 * _queueSize, 2);
	const uint32_t usedOff = align_up(availOff + availBytes, 4);

	uint8_t * base = (uint8_t *)_vqVirt;
	struct virtq_desc * descs = (struct virtq_desc *)base;
	uint16_t * availFlags = (uint16_t *)(base + availOff);
	uint16_t * availIdx = availFlags + 1;
	uint16_t * availRing = availIdx + 1;
	volatile uint16_t * usedIdxp = (volatile uint16_t *)(base + usedOff + 2);

	struct virtio_blk_req * req = (struct virtio_blk_req *)_hdrDesc->getBytesNoCopy();
	req->type = VIRTIO_BLK_T_IN;
	req->reserved = 0;
	req->sector = startBlock;
	volatile uint8_t * status = (volatile uint8_t *)_statusDesc->getBytesNoCopy();
	*status = 0xff;

	const uint16_t d0 = 0, d1 = 1, d2 = 2;
	descs[d0].addr = _hdrDesc->getPhysicalAddress();
	descs[d0].len = sizeof(struct virtio_blk_req);
	descs[d0].flags = VIRTQ_DESC_F_NEXT;
	descs[d0].next = d1;
	descs[d1].addr = dataDesc->getPhysicalAddress();
	descs[d1].len = (uint32_t)byteCount;
	descs[d1].flags = VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE;
	descs[d1].next = d2;
	descs[d2].addr = _statusDesc->getPhysicalAddress();
	descs[d2].len = 1;
	descs[d2].flags = VIRTQ_DESC_F_WRITE;
	descs[d2].next = 0;

	availRing[_availIdx % _queueSize] = d0;
	OSSynchronizeIO();
	_availIdx++;
	*availIdx = _availIdx;
	OSSynchronizeIO();
	mmioWrite(VIRTIO_MMIO_QUEUE_NOTIFY, 0);

	bool completed = false;
	for (int spin = 0; spin < 10000000; spin++) {
		OSSynchronizeIO();
		if (*usedIdxp != _usedIdx) {
			_usedIdx = *usedIdxp;
			completed = true;
			break;
		}
	}
	if (!completed) {
		/* A timed-out request still owns its DMA memory. Reset the device
		 * before releasing it; later requests fail until reinitialization. */
		mmioWrite(VIRTIO_MMIO_STATUS, 0);
		if (mmioRead(VIRTIO_MMIO_STATUS) != 0) {
			IOLog("IOVirtioBlk: reset pending; retaining DMA buffer\n");
			return kIOReturnTimeout;
		}
	}

	uint32_t isr = mmioRead(VIRTIO_MMIO_INTERRUPT_STATUS);
	if (isr) {
		mmioWrite(VIRTIO_MMIO_INTERRUPT_ACK, isr);
	}

	IOReturn kr = kIOReturnSuccess;
	if (!completed) {
		kr = kIOReturnTimeout;
	} else if (*status != 0) {
		kr = kIOReturnIOError;
	} else {
		bcopy(dataDesc->getBytesNoCopy(), buf, (size_t)byteCount);
	}

	dataDesc->complete();
	dataDesc->release();
	return kr;
}

IOReturn
IOVirtioBlk::doAsyncReadWrite(IOMemoryDescriptor * buffer,
    UInt64 block, UInt64 nblks,
    IOStorageAttributes * attributes,
    IOStorageCompletion * completion)
{
	(void) attributes;
	IOReturn status = kIOReturnSuccess;
	UInt64 actualByteCount = 0;

	if (!buffer || buffer->getDirection() != kIODirectionIn) {
		status = kIOReturnUnsupported;
		goto done;
	}
	if (block > _blockCount || nblks > _blockCount - block ||
	    nblks > buffer->getLength() / kVirtioBlkBlockSize) {
		status = kIOReturnBadArgument;
		goto done;
	}

	if (nblks != 0) {
		/* Bound the physically contiguous DMA allocation to 64 KiB. */
		const UInt64 scratchSize = ((nblks < 128) ? nblks : 128) * kVirtioBlkBlockSize;
		UInt8 * scratch = IONew(UInt8, scratchSize);
		if (!scratch) {
			status = kIOReturnNoMemory;
			goto done;
		}
		for (UInt64 offset = 0; offset < nblks;) {
			const UInt64 chunk = ((nblks - offset < 128) ? nblks - offset : 128);
			IOLockLock(_lock);
			status = readBlocks(block + offset, chunk, scratch);
			IOLockUnlock(_lock);
			if (status != kIOReturnSuccess) {
				break;
			}
			const UInt64 bytes = chunk * kVirtioBlkBlockSize;
			const UInt64 copied = buffer->writeBytes(actualByteCount, scratch, bytes);
			actualByteCount += copied;
			if (copied != bytes) {
				status = kIOReturnUnderrun;
				break;
			}
			offset += chunk;
		}
		IODelete(scratch, UInt8, scratchSize);
	}

done:
	if (completion && completion->action) {
		(*completion->action)(completion->target, completion->parameter, status, actualByteCount);
	}
	return kIOReturnSuccess;
}

IOReturn
IOVirtioBlk::doEjectMedia(void)
{
	return kIOReturnUnsupported;
}

IOReturn
IOVirtioBlk::doFormatMedia(UInt64 byteCapacity)
{
	(void) byteCapacity;
	return kIOReturnUnsupported;
}

UInt32
IOVirtioBlk::doGetFormatCapacities(UInt64 * capacities, UInt32 capacitiesMaxCount) const
{
	if (capacities && capacitiesMaxCount > 0) {
		capacities[0] = _blockCount * kVirtioBlkBlockSize;
	}
	return 1;
}

char *
IOVirtioBlk::getVendorString(void)
{
	return (char *) "virtio";
}

char *
IOVirtioBlk::getProductString(void)
{
	return (char *) "virtio-blk";
}

char *
IOVirtioBlk::getRevisionString(void)
{
	return (char *) "1.0";
}

char *
IOVirtioBlk::getAdditionalDeviceInfoString(void)
{
	return (char *) "";
}

IOReturn
IOVirtioBlk::reportBlockSize(UInt64 * blockSize)
{
	*blockSize = kVirtioBlkBlockSize;
	return kIOReturnSuccess;
}

IOReturn
IOVirtioBlk::reportEjectability(bool * isEjectable)
{
	*isEjectable = false;
	return kIOReturnSuccess;
}

IOReturn
IOVirtioBlk::reportMaxValidBlock(UInt64 * maxBlock)
{
	*maxBlock = (_blockCount > 0) ? (_blockCount - 1) : 0;
	return kIOReturnSuccess;
}

IOReturn
IOVirtioBlk::reportMediaState(bool * mediaPresent, bool * changedState)
{
	*mediaPresent = (_blockCount > 0);
	if (changedState) {
		*changedState = false;
	}
	return kIOReturnSuccess;
}

IOReturn
IOVirtioBlk::reportRemovability(bool * isRemovable)
{
	*isRemovable = false;
	return kIOReturnSuccess;
}

IOReturn
IOVirtioBlk::reportWriteProtection(bool * isWriteProtected)
{
	*isWriteProtected = true;
	return kIOReturnSuccess;
}

extern "C" {
kern_return_t IOVirtioBlk_start(kmod_info_t *, void *) { return KERN_SUCCESS; }
kern_return_t IOVirtioBlk_stop(kmod_info_t *, void *) { return KERN_SUCCESS; }
KMOD_EXPLICIT_DECL(org.opendarwin.driver.IOVirtioBlk, "1.0.0", IOVirtioBlk_start, IOVirtioBlk_stop)
}
