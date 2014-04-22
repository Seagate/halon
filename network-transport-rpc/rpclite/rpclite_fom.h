//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#pragma once


#include "rpclite_fop.h"

struct m0_fom_rpclite {
	/** Generic m0_fom object. */
        struct m0_fom                    fp_gen;
	/** FOP associated with this FOM. */
        struct m0_fop			*fp_fop;
};

struct rpc_item {
	struct m0_fop* fop;
};


int m0_fom_rpclite_state(struct m0_fom *fom);
size_t m0_fom_rpclite_home_locality(const struct m0_fom *fom);
void m0_fop_rpclite_fom_fini(struct m0_fom *fom);


