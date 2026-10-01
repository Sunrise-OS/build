/* Minimal stand-in for the DriverKit-backed IOUserBlockStorageDevice, which needs
 * iig-generated code. IOBlockStorageDriver only dynamic-casts to it and asks for a
 * perf control client, so a class that never has instances is enough. */
#pragma once
#include <IOKit/storage/IOBlockStorageDevice.h>
class IOPerfControlClient;
class IOUserBlockStorageDevice : public IOBlockStorageDevice {
	OSDeclareAbstractStructors(IOUserBlockStorageDevice);
public:
	IOPerfControlClient *getPerfControlClient(void) { return NULL; }
};
