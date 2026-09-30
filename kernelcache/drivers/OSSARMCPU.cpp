#include "OSSARMCPU.h"
#include <mach/kmod.h>

extern "C" {
#include <pexpert/pexpert.h>
}

#include <machine/machine_routines.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOPlatformExpert.h>
#include <IOKit/IOService.h>
#include <IOKit/IOCPU.h>
#include <kern/thread.h>

OSDefineMetaClassAndStructors(OSSARMCPU, IOCPU);

void
OSSARMCPU::configureCPUNumber(UInt32 cpuNumber)
{
	setCPUNumber(cpuNumber);
}

void
OSSARMCPU::initCPU(bool /*boot*/)
{
	setCPUState(kIOCPUStateRunning);
}

void
OSSARMCPU::quiesceCPU(void)
{
}

kern_return_t
OSSARMCPU::startCPU(vm_offset_t /*start_paddr*/, vm_offset_t /*arg_paddr*/)
{
	/* Secondary CPU bring-up is not implemented on these boards. */
	return KERN_FAILURE;
}

void
OSSARMCPU::haltCPU(void)
{
}

const OSSymbol *
OSSARMCPU::getCPUName(void)
{
	char name[16];

	snprintf(name, sizeof(name), "CPU%u", (unsigned int)getCPUNumber());
	return OSSymbol::withCString(name);
}

static IOCPUInterruptController *gOSSCPUInterruptController;

/* Bounded wait for the platform expert: 100ms * 600 = up to 60s. */
#define OSS_PLATFORM_WAIT_MS     100
#define OSS_PLATFORM_WAIT_TRIES  600

static void
oss_arm_cpu_publish_thread(void */*arg*/, wait_result_t /*wr*/)
{
	IOService *platform = NULL;

	for (int i = 0; i < OSS_PLATFORM_WAIT_TRIES; i++) {
		platform = IOService::getPlatform();
		if (platform != NULL) {
			break;
		}
		IOSleep(OSS_PLATFORM_WAIT_MS);
	}

	if (platform == NULL) {
		IOLog("OSSARMCPU: no platform expert appeared; "
		    "CPU interrupt controller left unregistered\n");
		return;
	}

	if (!gOSSCPUInterruptController->attach(platform)) {
		IOLog("OSSARMCPU: failed to attach CPU interrupt controller\n");
		return;
	}
	gOSSCPUInterruptController->registerCPUInterruptController();

	const ml_topology_info_t *topology = ml_get_topology_info();
	for (unsigned int cpu = 0; topology != NULL && cpu < topology->num_cpus; cpu++) {
		const ml_topology_cpu *cpu_info = &topology->cpus[cpu];
		ml_processor_info_t this_processor_info;
		processor_t processor = NULL;
		ipi_handler_t ipi_handler = NULL;
		perfmon_interrupt_handler_func pmi_handler = NULL;

		OSSARMCPU *iocpu = new OSSARMCPU;
		if (iocpu == NULL || !iocpu->init()) {
			panic("OSSARMCPU: failed to create IOCPU for cpu %u",
			    cpu_info->cpu_id);
		}
		iocpu->configureCPUNumber(cpu_info->cpu_id);

		memset(&this_processor_info, 0, sizeof(this_processor_info));
		this_processor_info.cpu_id = (cpu_id_t)iocpu;
		this_processor_info.phys_id = cpu_info->phys_id;
		this_processor_info.log_id = cpu_info->cpu_id;
		this_processor_info.cluster_id = cpu_info->cluster_id;
		this_processor_info.cluster_type = cpu_info->cluster_type;
		this_processor_info.l2_cache_size = cpu_info->l2_cache_size;
		this_processor_info.l2_cache_id = cpu_info->l2_cache_id;
		this_processor_info.l3_cache_size = cpu_info->l3_cache_size;
		this_processor_info.l3_cache_id = cpu_info->l3_cache_id;

		if (ml_processor_register(&this_processor_info, &processor,
		    &ipi_handler, &pmi_handler) == KERN_FAILURE) {
			panic("OSSARMCPU: ml_processor_register failed for cpu %u",
			    cpu_info->cpu_id);
		}
	}

	ml_cpu_init_completed();
	IOService::publishResource(gIOAllCPUInitializedKey, kOSBooleanTrue);
}

extern "C" kern_return_t
OSSARMCPU_start(kmod_info_t * /*ki*/, void * /*d*/)
{
	const ml_topology_info_t *topology = ml_get_topology_info();
	unsigned int num_cpus = (topology != NULL && topology->num_cpus > 0) ?
	    topology->num_cpus : 1;

	gOSSCPUInterruptController = new IOCPUInterruptController;
	if (gOSSCPUInterruptController == NULL) {
		panic("OSSARMCPU: failed to allocate IOCPUInterruptController");
	}

	if (gOSSCPUInterruptController->initCPUInterruptController((int)num_cpus)
	    != kIOReturnSuccess) {
		panic("OSSARMCPU: initCPUInterruptController(%u) failed", num_cpus);
	}

	thread_t thread;
	if (kernel_thread_start(&oss_arm_cpu_publish_thread, NULL, &thread) != KERN_SUCCESS) {
		panic("OSSARMCPU: failed to start cpu publish thread");
	}
	thread_set_thread_name(thread, "oss_arm_cpu_publish");
	thread_deallocate(thread);
	return KERN_SUCCESS;
}

extern "C" kern_return_t
OSSARMCPU_stop(kmod_info_t * /*ki*/, void * /*d*/)
{
	return KERN_SUCCESS;
}

extern "C" {
KMOD_EXPLICIT_DECL(org.opendarwin.driver.OSSARMCPU, "1.0.0", OSSARMCPU_start, OSSARMCPU_stop)
}
