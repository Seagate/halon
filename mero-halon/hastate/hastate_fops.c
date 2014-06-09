//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#include "fop/fom_generic.h"
#include "fop/fop.h"
#include "halon/note_xc.h"
#include "halon/note_fops.h"
#include "halon/note_fops_xc.h"
#include "rpc/rpc.h"
#include "rpc/rpc_opcodes.h"

#include "hastate_fops.h"
#include "hastate_foms.h"

extern struct m0_reqh_service_type m0_rpc_service_type;

struct m0_fop_type ha_state_set_fopt;
struct m0_fop_type ha_state_get_fopt;
struct m0_fop_type ha_state_get_rep_fopt;

void ha_state_fop_fini(void)
{
    m0_fop_type_fini(&ha_state_get_fopt);
    m0_fop_type_fini(&ha_state_get_rep_fopt);
    m0_fop_type_fini(&ha_state_set_fopt);
    m0_xc_note_fini();
    m0_xc_note_fops_fini();
}

int ha_state_fop_init(void)
{
    m0_xc_note_init();
    m0_xc_note_fops_init();
    M0_FOP_TYPE_INIT(&ha_state_get_fopt,
                     .name      = "M0 State Get",
                     .opcode    = M0_HA_NOTE_GET_OPCODE,
                     .xt        = m0_ha_state_fop_get_xc,
                     .rpc_flags = M0_RPC_ITEM_TYPE_REQUEST,
                     .fom_ops   = &ha_state_get_fom_type_ops,
                     .sm        = &m0_generic_conf,
                     .svc_type  = &m0_rpc_service_type);
    M0_FOP_TYPE_INIT(&ha_state_get_rep_fopt,
                     .name      = "HA State Get Reply",
                     .opcode    = M0_HA_NOTE_GET_REP_OPCODE,
                     .xt        = m0_ha_state_fop_get_rep_xc,
                     .rpc_flags = M0_RPC_ITEM_TYPE_REPLY,
                     .svc_type  = &m0_rpc_service_type);
    M0_FOP_TYPE_INIT(&ha_state_set_fopt,
                     .name      = "M0 State Set",
                     .opcode    = M0_HA_NOTE_SET_OPCODE,
                     .xt        = m0_ha_nvec_xc,
                     .rpc_flags = M0_RPC_ITEM_TYPE_REQUEST,
                     .fom_ops   = &ha_state_set_fom_type_ops,
                     .sm        = &m0_generic_conf,
                     .svc_type  = &m0_rpc_service_type);
    return 0;
}
