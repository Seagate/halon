//
// Copyright (C) 2015 Seagate Technology Limited. All rights reserved.
//
#include "m0init.h"
#include "module/instance.h"
#include "mero/init.h"
#include "mero/version.h"
#include <stdio.h>
#include <stdlib.h>

static struct m0 instance;

int m0_init_wrapper () {
    const struct m0_build_info* bi = m0_build_info_get();
    if (0 != strcmp(bi->bi_git_rev_id, M0_VERSION_GIT_REV_ID)) {
      fprintf(stderr, "m0_init_wrapper: The loaded mero library (%s) "
                      "is not the expected one (%s)\n"
                    , bi->bi_git_rev_id
                    , M0_VERSION_GIT_REV_ID
             );
      exit(1);
    }
    M0_SET0(&instance);
    return m0_init(&instance);
}
