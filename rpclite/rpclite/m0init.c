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
    const struct m0_build_info* bi = m0_build_info_get();
    int disable_compat_check = getenv("DISABLE_MERO_COMPAT_CHECK") == NULL;
    if (0 != strcmp(bi->bi_git_rev_id, M0_VERSION_GIT_REV_ID)) {
      fprintf(stderr, "m0_init_wrapper: The loaded mero library (%s) "
                      "is not the expected one (%s)\n"
                    , bi->bi_git_rev_id
                    , M0_VERSION_GIT_REV_ID
             );
      if (disable_compat_check) {
        exit(1);
      }
    }
    if (0 != strcmp(bi->bi_configure_opts, M0_VERSION_BUILD_CONFIGURE_OPTS)) {
      fprintf(stderr, "m0_init_wrapper: the configuration options of the "
                      "loaded mero library (%s) do not match the expected ones "
                      "(%s)\n"
                    , bi->bi_configure_opts
                    , M0_VERSION_BUILD_CONFIGURE_OPTS
             );
      if (disable_compat_check) {
        exit(1);
      }
    }
    return m0_halon_interface_init( &m0init_hi
                                  , M0_VERSION_GIT_REV_ID
                                  , M0_VERSION_BUILD_CONFIGURE_OPTS
                                  , disable_compat_check
                                  , NULL);
}

void m0_fini_wrapper() {
    m0_halon_interface_fini(m0init_hi);
}
