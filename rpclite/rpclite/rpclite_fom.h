//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#pragma once

#include "config.h"
#include "rpclite_fop.h"

struct rpc_item {
	struct m0_fop* fop;
};

int m0_fom_rpclite_state(struct m0_fom *fom);
size_t m0_fom_rpclite_home_locality(const struct m0_fom *fom);
void m0_fop_rpclite_fom_fini(struct m0_fom *fom);


