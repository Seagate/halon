//
// Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//

#include "rpclite_fop.h"
#include "rpclite_fop_ff.h"
#include "rpclite_fom.h"

#include "lib/errno.h"
#include "lib/memory.h"
#include "fop/fom.h"
#include "fop/fop.h"
#include "lib/errno.h"
#include "rpc/rpc.h"
#include "fop/fop_item_type.h"
#include "fop/fom_generic.h"

struct m0_fop_type m0_fop_rpclite_fopt;
struct m0_fop_type m0_fop_rpclite_rep_fopt;

void rpclite_fop_fini(void)
{
	m0_fop_type_fini(&m0_fop_rpclite_rep_fopt);
        m0_fop_type_fini(&m0_fop_rpclite_fopt);
	m0_xc_rpclite_fop_fini();
}

extern const struct m0_fom_type_ops m0_fom_rpclite_type_ops;
extern struct m0_reqh_service_type m0_rpc_service_type;

int rpclite_fop_init(void)
{
	m0_xc_rpclite_fop_init();
    M0_FOP_TYPE_INIT(&m0_fop_rpclite_fopt,
			 .name      = "Ping fop",
			 .opcode    = M0_RPC_PING_OPCODE,
			 .xt        = rpclite_fop_xc,
			 .rpc_flags = M0_RPC_ITEM_TYPE_REQUEST |
				      M0_RPC_ITEM_TYPE_MUTABO,
			 .fom_ops   = &m0_fom_rpclite_type_ops,
			 .sm        = &m0_generic_conf,
             .svc_type  = &m0_rpc_service_type);
	M0_FOP_TYPE_INIT(&m0_fop_rpclite_rep_fopt,
			 .name      = "Ping fop reply",
			 .opcode    = M0_RPC_PING_REPLY_OPCODE,
			 .xt        = rpclite_fop_rep_xc,
			 .rpc_flags = M0_RPC_ITEM_TYPE_REPLY,
             .svc_type  = &m0_rpc_service_type);
	return 0;
}

