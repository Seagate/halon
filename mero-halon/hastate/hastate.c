//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//
// This is the hastate interface. It allows to react to request produced by
// mero through the interpretive interface.
//

#define M0_TRACE_SUBSYSTEM M0_TRACE_SUBSYS_HA
#include "lib/trace.h"
#include "lib/memory.h"
#include "lib/string.h"   /* m0_strdup */
#include "hastate.h"
#include "fop/fop.h"
#include "ha/note_fops.h" /* m0_ha_state_fop */

#include "hastate_foms.h"

#include <stdio.h>

// To hold callbacks.
ha_state_callbacks_t ha_state_cbs;

// Initializes the ha_state interface.
int ha_state_init(ha_state_callbacks_t *cbs) {
    ha_state_cbs = *cbs;
    m0_ha_state_get_fom_type_ops  = &ha_state_get_fom_type_ops;
    m0_ha_state_set_fom_type_ops  = &ha_state_set_fom_type_ops;
    m0_ha_entrypoint_fom_type_ops = &ha_entrypoint_fom_type_ops;
    return 0;
}

// Wake up state get FOM.
void ha_state_get_done(struct m0_ha_nvec *note, int rc) {
     struct ha_state_get_fom        *fom_obj;

     fom_obj = M0_AMB(fom_obj, note, fp_note);
     fom_obj->fp_rc = rc;
     m0_fom_wakeup(&fom_obj->fp_gen);
}

// Finalizes the ha_state interface.
void ha_state_fini() {
}

// Avoids destroying the payload of the fop.
static void notify_fop_release(struct m0_ref *ref) {
    container_of(ref, struct m0_fop, f_ref)->f_data.fd_data = NULL;
    m0_fop_release(ref);
}

/// Notifies mero at the remote address that the state of some objects has changed.
int ha_state_notify( rpc_endpoint_t *ep, char *remote_address
                   , struct m0_ha_nvec *note, int timeout_s
                   ) {
    int rc;
    int i;
    struct m0_fop *fop;
    rpc_connection_t *c;
    rc = rpc_connect(ep,remote_address,timeout_s,&c);
    if (rc)
        return rc;

    M0_ALLOC_PTR(fop);
    M0_ASSERT(fop != NULL);
    m0_fop_init(fop, &m0_ha_state_set_fopt, note, notify_fop_release);

    M0_LOG(M0_ALWAYS, "sending notification so endpoint=%s note->nv_nr=%"PRIi32,
	   remote_address, note->nv_nr);
    for (i = 0; i < note->nv_nr; ++i) {
	    M0_LOG(M0_ALWAYS, "note->nv_note[%d] no_id="FID_F" no_state=%u",
	           i, FID_P(&note->nv_note[i].no_id),
	           note->nv_note[i].no_state);
    }
    rc = rpc_send_fop_blocking_and_release(c,fop,timeout_s);

    rpc_disconnect(c,timeout_s);
    M0_LOG(M0_ALWAYS, "sent    notification so endpoint=%s", remote_address);
    return rc;
}

// Populates m0_ha_entrypoint_rep structure by values from haskell world.
void ha_entrypoint_reply_wakeup( struct m0_fom               *fom
                               , struct m0_ha_entrypoint_rep *rep_fop
                               , const int                    rc
                               , int                          confd_fid_size
                               , const struct m0_fid         *confd_fid_data
                               , int                          confd_eps_size
                               , const char *                *confd_eps_data
                               , const struct m0_fid         *rm_fid
                               , const char *                 rm_eps
                               ) {
   rep_fop->hbp_rc = rc;
   if (rc != 0) goto wakeup;

   char *rm_ep = m0_strdup(rm_eps);
   M0_ALLOC_ARR(rep_fop->hbp_confd_fids.af_elems, confd_fid_size);
   M0_ALLOC_ARR(rep_fop->hbp_confd_eps.ab_elems,  confd_eps_size);
   if (rm_ep == NULL ||
       rep_fop->hbp_confd_fids.af_elems == NULL ||
       rep_fop->hbp_confd_eps.ab_elems == NULL) {
         m0_free(rm_ep);
         m0_free(rep_fop->hbp_confd_fids.af_elems);
         m0_free(rep_fop->hbp_confd_eps.ab_elems);
         rep_fop->hbp_rc = -ENOMEM;
         goto wakeup;
   }
   if (0 != m0_bufs_from_strings(&rep_fop->hbp_confd_eps, confd_eps_data)) {
         m0_free(rm_ep);
         m0_free(rep_fop->hbp_confd_fids.af_elems);
         m0_free(rep_fop->hbp_confd_eps.ab_elems);
         rep_fop->hbp_rc = -ENOMEM;
         goto wakeup;
   }
   rep_fop->hbp_active_rm_fid = *rm_fid;
   rep_fop->hbp_active_rm_ep  = M0_BUF_INITS(rm_ep);
   rep_fop->hbp_confd_fids.af_count = confd_fid_size;
   memcpy(rep_fop->hbp_confd_fids.af_elems, confd_fid_data, confd_fid_size*(sizeof confd_fid_data[0]));
   rep_fop->hbp_quorum = confd_fid_size / 2 + 1;

wakeup:
   m0_fom_wakeup(fom);
}
