//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#pragma once

#include "fop/fop.h"
#include "rpc/rpc_opcodes.h"

int rpclite_fop_init(void);
void rpclite_fop_fini(void);

/**
 * FOP definitions and corresponding fop type formats
 */
extern struct m0_fop_type m0_fop_rpclite_fopt;
extern struct m0_fop_type m0_fop_rpclite_rep_fopt;

extern const struct m0_fop_type_ops m0_fop_rpclite_ops;
extern const struct m0_fop_type_ops m0_fop_rpclite_rep_ops;

extern const struct m0_rpc_item_type m0_rpc_item_type_rpclite;
extern const struct m0_rpc_item_type m0_rpc_item_type_rpclite_rep;

