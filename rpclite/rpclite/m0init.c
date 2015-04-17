//
// Copyright (C) 2015 Seagate Technology Limited. All rights reserved.
//
#include "m0init.h"
#include "module/instance.h"
#include "mero/init.h"

static struct m0 instance;

int m0_init_wrapper () {
    M0_SET0(&instance);
    return m0_init(&instance);
}
