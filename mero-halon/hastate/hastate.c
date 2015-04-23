//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//
// This is the hastate interface. It allows to react to request produced by
// mero through the interpretive interface.
//

#include "hastate.h"
#include "hastate_fops.h"

#include "fop/fop.h"
#include "ha/note_fops.h"
#include "lib/memory.h"

#include "hastate_foms.h"
#include <stdio.h>

// To hold callbacks.
ha_state_callbacks_t *ha_state_cbs;

// Initializes the ha_state interface.
int ha_state_init(ha_state_callbacks_t *cbs) {
    ha_state_cbs = cbs;
    ha_state_fop_init();
    return 0;
}

void ha_state_get_done(struct m0_ha_nvec *note,int rc) {
     struct ha_state_get_fom        *fom_obj;

     fom_obj = M0_AMB(fom_obj, note, fp_note);
     fom_obj->fp_rc = rc;
     m0_fom_wakeup(&fom_obj->fp_gen);
}

// Finalizes the ha_state interface.
void ha_state_fini() {
    ha_state_fop_fini();
}

// Avoids destroying the payload of the fop.
static void notify_fop_release(struct m0_ref *ref) {
    container_of(ref, struct m0_fop, f_ref)->f_data.fd_data = NULL;
    m0_fop_release(ref);
}

/// Notifies mero at the remote address that the state of some objects has changed.
int ha_state_notify( rpc_receive_endpoint_t *ep, char *remote_address
                   , struct m0_ha_nvec *note, int timeout_s
                   ) {
    int rc;
    struct m0_fop *fop;
    rpc_connection_t *c;
    rc = rpc_connect_re(ep,remote_address,timeout_s,&c);
    if (rc)
        return rc;

    M0_ALLOC_PTR(fop);
    M0_ASSERT(fop != NULL);
    m0_fop_init(fop,&ha_state_set_fopt, note, notify_fop_release);

    rc = rpc_send_fop_blocking_and_release(c,fop,timeout_s);

    rpc_disconnect(c,timeout_s);
    return rc;
}
