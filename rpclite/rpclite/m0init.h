//
// Copyright (C) 2015-2018 Seagate Technology LLC and/or its Affiliates. Apache License, Version 2.0.
//
#pragma once
#ifndef __H0_M0INIT_H__
#define __H0_M0INIT_H__

struct m0_halon_interface;

extern struct m0_halon_interface *m0init_hi;

int m0_init_wrapper(void);
void m0_fini_wrapper(void);

#endif  // __H0_M0INIT_H__
