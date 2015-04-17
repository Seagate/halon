//
// Copyright (C) 2015 Seagate Technology Limited. All rights reserved.
//
#pragma once

#include "HsFFI.h"
#include "lib/thread.h"

/// Runs the given action in an M0_THREAD
int forkM0OS_createThread (struct m0_thread* t, HsFunPtr action);

/// Waits for a given m0_thread to finish.
int forkM0OS_joinThread (struct m0_thread* t);
