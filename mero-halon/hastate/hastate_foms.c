//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#include "fop/fom.h"
#include "fop/fom_generic.h"
#include "ha/note_fops.h"
#include "lib/errno.h"
#include "lib/memory.h"
#include "lib/trace.h"

#include "hastate.h"
#include "hastate_foms.h"
#include "hastate_fops.h"

extern ha_state_callbacks_t *ha_state_cbs;

/*
 * Common functions for Get and Set FOM ops
 */

size_t ha_state_fom_locality(const struct m0_fom *fom)
{
     M0_PRE(fom != NULL);
     return m0_fop_opcode(fom->fo_fop);
}

void ha_state_fom_addb_init(struct m0_fom *fom, struct m0_addb_mc *mc)
{
     fom->fo_addb_ctx.ac_magic = M0_ADDB_CTX_MAGIC;
}


/*
 * Get FOM
 */

struct ha_state_get_fom {
     struct m0_fom  fp_gen;
     struct note_context fp_ctx;
     struct m0_fop* fp_fop;
};


void ha_state_get_fom_fini(struct m0_fom *fom)
{
     struct ha_state_get_fom *fom_obj;
     fom_obj = container_of(fom, struct ha_state_get_fom, fp_gen);
     m0_fom_fini(fom);
     m0_free(fom_obj);
}

int ha_state_get_fom_tick(struct m0_fom *fom)
{
     struct m0_fop              *fop;
     struct m0_ha_state_fop_get_rep *fop_get_rep;
     struct m0_ha_state_fop_get *fop_get;
     struct m0_ha_nvec          *note;
     struct ha_state_get_fom    *fom_obj;
     struct note_context        *ctx;
     int                         rc = 0;
     int                         i;

     fom_obj = container_of(fom, struct ha_state_get_fom, fp_gen);

     if (m0_fom_phase(fom) != M0_FOPH_TYPE_SPECIFIC) {
         fop_get = m0_fop_data(fom_obj->fp_fop);

         note = &fom_obj->fp_ctx.nc_note;
         note->nv_nr = fop_get->hsg_ids.ni_nr;
         M0_ALLOC_ARR(note->nv_note,note->nv_nr);
         for (i = 0; i < note->nv_nr; ++i) {
             note->nv_note[i].no_id = fop_get->hsg_ids.ni_id_types[i];
         }

         m0_fom_phase_set(fom, M0_FOPH_TYPE_SPECIFIC);
         ha_state_cbs->ha_state_get(note);

     } else {

         ctx = &fom_obj->fp_ctx;
         note = &ctx->nc_note;
         fop = m0_fop_reply_alloc(fom_obj->fp_fop, &ha_state_get_rep_fopt);
         M0_ASSERT(fop != NULL);

         fop_get_rep                  = m0_fop_data(fop);
         fop_get_rep->hsgr_rc         = ctx->nc_rc;
         fop_get_rep->hsgr_note.nv_nr = note->nv_nr;
         M0_ALLOC_ARR(fop_get_rep->hsgr_note.nv_note, note->nv_nr);
         for (i = 0; i < note->nv_nr; ++i)
             fop_get_rep->hsgr_note.nv_note[i] = note->nv_note[i];

         m0_rpc_reply_post(m0_fop_to_rpc_item(fom_obj->fp_fop), m0_fop_to_rpc_item(fop));

         m0_free(note->nv_note);
         m0_fom_phase_set(fom, M0_FOPH_FINISH);
     }

     return M0_FSO_WAIT;
}

const struct m0_fom_ops ha_state_get_fom_ops = {
    .fo_tick          = ha_state_get_fom_tick,
    .fo_fini          = ha_state_get_fom_fini,
    .fo_home_locality = ha_state_fom_locality,
    .fo_addb_init     = ha_state_fom_addb_init
};

int ha_state_get_fom_create(struct m0_fop *fop, struct m0_fom **m,
                            struct m0_reqh *reqh)
{
     struct m0_fom           *fom;
     struct ha_state_get_fom *fom_obj;
     int                      rc = 0;

     M0_PRE(fop != NULL);
     M0_PRE(m != NULL);

     M0_ALLOC_PTR(fom_obj);
     if (fom_obj == NULL)
          return -ENOMEM;

     fom = &fom_obj->fp_gen;
     m0_fom_init(fom, &fop->f_type->ft_fom_type, &ha_state_get_fom_ops, fop,
                 NULL, reqh);

     fom_obj->fp_fop = fop;
     fom_obj->fp_ctx.nc_fom = fom;
     *m = fom;

     return rc;
}

const struct m0_fom_type_ops ha_state_get_fom_type_ops = {
    .fto_create = ha_state_get_fom_create
};


/*
 * Set FOM
 */

struct ha_state_set_fom {
     struct m0_fom  fp_gen;
     struct m0_fop *fp_fop;
};

void ha_state_set_fom_fini(struct m0_fom *fom)
{
     struct ha_state_set_fom *fom_obj;
     fom_obj = container_of(fom, struct ha_state_set_fom, fp_gen);
     m0_fom_fini(fom);
     m0_free(fom_obj);
}

int ha_state_set_fom_tick(struct m0_fom *fom)
{
     struct m0_fop               *fop;
     struct m0_fop_generic_reply *fop_rep;
     struct m0_rpc_item          *item;
     struct m0_ha_nvec           *note;
     struct ha_state_set_fom     *fom_obj;
     int                          rc;

     fom_obj = container_of(fom, struct ha_state_set_fom, fp_gen);

     fop = m0_fop_reply_alloc(fom_obj->fp_fop, &m0_fop_generic_reply_fopt);
     M0_ASSERT(fop != NULL);

     note = m0_fop_data(fom_obj->fp_fop);

     rc = ha_state_cbs->ha_state_set(note);

     if (rc != 0) {
          M0_LOG(M0_DEBUG,"ha_state_cbs->ha_state_set: %d\n",rc);
     }

     fop_rep               = m0_fop_data(fop);
     fop_rep->gr_rc        = rc;
     fop_rep->gr_msg.s_len = 0;

     item = m0_fop_to_rpc_item(fop);
     m0_rpc_reply_post(m0_fop_to_rpc_item(fom_obj->fp_fop), item);
     m0_fom_phase_set(fom, M0_FOPH_FINISH);

     return M0_FSO_WAIT;
}

const struct m0_fom_ops ha_state_set_fom_ops = {
     .fo_tick          = ha_state_set_fom_tick,
     .fo_fini          = ha_state_set_fom_fini,
     .fo_home_locality = ha_state_fom_locality,
     .fo_addb_init     = ha_state_fom_addb_init
};

int ha_state_set_fom_create(struct m0_fop *fop, struct m0_fom **m,
                            struct m0_reqh *reqh)
{
     struct m0_fom           *fom;
     struct ha_state_set_fom *fom_obj;
     int                      rc = 0;

     M0_PRE(fop != NULL);
     M0_PRE(m != NULL);

     M0_ALLOC_PTR(fom_obj);
     if (fom_obj == NULL)
          return -ENOMEM;

     fom = &fom_obj->fp_gen;
     m0_fom_init(fom, &fop->f_type->ft_fom_type, &ha_state_set_fom_ops, fop,
                 NULL, reqh);

     fom_obj->fp_fop = fop;
     *m = fom;

     return rc;
}

const struct m0_fom_type_ops ha_state_set_fom_type_ops = {
     .fto_create = ha_state_set_fom_create
};
