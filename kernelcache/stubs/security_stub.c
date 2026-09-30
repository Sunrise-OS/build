/*
 * Minimal stand-ins for the closed-source AppleImage4 and AppleMobileFileIntegrity
 * kexts, so XNU's startup finds img4if and amfi registered.
 *
 * NOTHING HERE ENFORCES ANYTHING. The trust cache is permanently empty (queries
 * report "not found", loads are unsupported) and the entitlement hooks fail. This
 * is for bringing the kernel up in an emulator, not for running untrusted code.
 */
#include <mach/mach_types.h>
#include <mach/kmod.h>
#include <libkern/img4/interface.h>
#include <libkern/amfi/amfi.h>

static TCReturn_t
tc_result(uint8_t error)
{
	TCReturn_t r = { 0 };
	r.component = kTCComponentLoad;
	r.error = error;
	return r;
}

/* The trust-cache entry points only differ in arguments, which these ignore. */
static TCReturn_t tc_unsupported(void) { return tc_result(kTCReturnUnsupported); }
static TCReturn_t tc_not_found(void) { return tc_result(kTCReturnNotFound); }

static void os_ent_invalidate(void *e) { (void)e; }
static void *os_ent_asdict(void *e) { (void)e; return NULL; }
static bool os_ent_false(void) { return false; }
static kern_return_t os_ent_unsupported(void) { return KERN_NOT_SUPPORTED; }

static const img4_interface_t img4_stub = {
	.i4if_version = IMG4_INTERFACE_VERSION,
};

static const amfi_t amfi_stub = {
	.OSEntitlements_invalidate = os_ent_invalidate,
	.OSEntitlements_asdict = os_ent_asdict,
	.OSEntitlements_query = (amfi_OSEntitlements_query)os_ent_unsupported,
	.OSEntitlements_get_transmuted = (amfi_OSEntitlements_get_transmuted_blob)os_ent_false,
	.OSEntitlements_get_xml = (amfi_OSEntitlements_get_xml_blob)os_ent_false,
	.get_legacy_profile_exemptions = (amfi_get_legacy_profile_exemptions)os_ent_false,
	.get_udid = (amfi_get_udid)os_ent_false,
	.TrustCache = {
		.version = TRUST_CACHE_INTERFACE_VERSION,
		.loadModule = (loadModule_t)tc_unsupported,
		.load = (load_t)tc_unsupported,
		.query = (query_t)tc_not_found,
		.getCapabilities = (getCapabilities_t)tc_unsupported,
		.queryGetTCType = (queryGetTCType_t)tc_unsupported,
		.queryGetCapabilities = (queryGetCapabilities_t)tc_unsupported,
		.queryGetHashType = (queryGetHashType_t)tc_unsupported,
		.queryGetFlags = (queryGetFlags_t)tc_unsupported,
		.queryGetConstraintCategory = (queryGetConstraintCategory_t)tc_unsupported,
		.queryGetUUID = (queryGetUUID_t)tc_unsupported,
		.constructInvalid = (constructInvalid_t)tc_unsupported,
		.checkRuntimeForUUID = (checkRuntimeForUUID_t)tc_not_found,
		.extractModule = (extractModule_t)tc_unsupported,
		.getModule = (getModule_t)tc_unsupported,
		.getUUID = (getUUID_t)tc_unsupported,
	},
	.OSEntitlements = {
		.version = OSENTITLEMENTS_INTERFACE_VERSION,
		.adjustContext = (OSEntitlements_adjustContext)os_ent_unsupported,
		.adjustContextWithMonitor = (OSEntitlements_adjustContextWithMonitor)os_ent_unsupported,
		.adjustContextWithoutMonitor = (OSEntitlements_adjustContextWithoutMonitor)os_ent_unsupported,
		.queryEntitlementBoolean = (OSEntitlements_queryEntitlementBoolean)os_ent_unsupported,
		.queryEntitlementBooleanWithProc = (OSEntitlements_queryEntitlementBooleanWithProc)os_ent_unsupported,
		.queryEntitlementString = (OSEntitlements_queryEntitlementString)os_ent_unsupported,
		.queryEntitlementStringWithProc = (OSEntitlements_queryEntitlementStringWithProc)os_ent_unsupported,
		.copyEntitlementAsOSObject = (OSEntitlements_copyEntitlementAsOSObject)os_ent_unsupported,
		.copyEntitlementAsOSObjectWithProc = (OSEntitlements_copyEntitlementAsOSObjectWithProc)os_ent_unsupported,
	},
	.has_mte_soft_mode = (amfi_has_mte_soft_mode)os_ent_false,
	.has_mte_opt_out = (amfi_has_mte_opt_out)os_ent_false,
	.has_mte_inheritance_opt_out = (amfi_has_mte_inheritance_opt_out)os_ent_false,
	.has_mte_data_tagging_opt_out = (amfi_has_mte_data_tagging_override)os_ent_false,
	.has_mte_alias_restriction_opt_in = (amfi_has_mte_alias_restriction_opt_in)os_ent_false,
};

kern_return_t security_stub_start(kmod_info_t *ki, void *d);
kern_return_t security_stub_stop(kmod_info_t *ki, void *d);

kern_return_t
security_stub_start(kmod_info_t *ki, void *d)
{
	(void)ki; (void)d;
	img4_interface_register(&img4_stub);
	amfi_interface_register(&amfi_stub);
	return KERN_SUCCESS;
}

kern_return_t
security_stub_stop(kmod_info_t *ki, void *d)
{
	(void)ki; (void)d;
	return KERN_FAILURE; /* the kernel keeps pointers into this image */
}

KMOD_EXPLICIT_DECL(com.apple.kec.security-stub, "1.0.0", security_stub_start, security_stub_stop)
