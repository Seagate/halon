//
// Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//

#pragma once

#include "config.h"
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

