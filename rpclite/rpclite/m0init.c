//
// Copyright (C) 2015 Seagate Technology Limited. All rights reserved.
//
#include "m0init.h"
#include "ha/halon/interface.h"
#include "lib/memory.h"
#include "mero/init.h"
#include "mero/version.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct m0_halon_interface* m0init_hi = NULL;

int m0_init_wrapper () {
    return m0_halon_interface_init( &m0init_hi
                                  , M0_VERSION_GIT_REV_ID
                                  , M0_VERSION_BUILD_CONFIGURE_OPTS
                                  , getenv("DISABLE_MERO_COMPAT_CHECK") != NULL
                                  , NULL);
}

void m0_fini_wrapper() {
    m0_halon_interface_fini(m0init_hi);
}
