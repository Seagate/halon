//
// Copyright (C) 2015-2018 Seagate Technology LLC and/or its Affiliates. Apache License, Version 2.0.
//

#define M0_TRACE_SUBSYSTEM M0_TRACE_SUBSYS_HA
#include "lib/trace.h"

#include "m0init.h"

#include "ha/halon/interface.h"
#include "mero/version.h"        // M0_VERSION_GIT_REV_ID
#include <stdlib.h>              // getenv

struct m0_halon_interface *m0init_hi = NULL;

int m0_init_wrapper(void)
{
	M0_PRE(m0init_hi == NULL);
	return m0_halon_interface_init(
		&m0init_hi,
		M0_VERSION_GIT_REV_ID,
		M0_VERSION_BUILD_CONFIGURE_OPTS,
		getenv("HALON_INTERFACE_DEBUG_OPTIONS"),
		NULL);
}

void m0_fini_wrapper(void)
{
	m0_halon_interface_fini(m0init_hi);
	m0init_hi = NULL;
}

#undef M0_TRACE_SUBSYSTEM
