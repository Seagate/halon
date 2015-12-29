//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#define M0_TRACE_SUBSYSTEM M0_TRACE_SUBSYS_HA
#include "lib/trace.h"
#include "hastate.h"
#include "hastate_foms.h"

#include "fop/fom.h"
#include "fop/fom_generic.h"
#include "ha/note_fops.h"
#include "lib/errno.h"
#include "lib/memory.h"
#include "lib/trace.h"

extern ha_state_callbacks_t ha_state_cbs;

/*
 * Common functions for Get and Set FOM ops
 */

size_t ha_state_fom_locality(const struct m0_fom *fom)
{
    return m0_fop_opcode(fom->fo_fop);
}

/*
 * Get FOM
 */

void ha_state_get_fom_fini(struct m0_fom *fom)
{
     struct ha_state_get_fom *fom_obj;
     fom_obj = M0_AMB(fom_obj, fom, fp_gen);
     m0_fom_fini(fom);
     m0_free(fom_obj->fp_note.nv_note);
     m0_free(fom_obj);
}

int ha_state_get_fom_tick(struct m0_fom *fom)
{
    struct ha_state_get_fom    *fom_obj;
    struct m0_ha_state_fop     *fop_get_rep;
    struct m0_ha_nvec          *note;
    int                         rc = 0;
    int                         i;

    fom_obj = M0_AMB(fom_obj, fom, fp_gen);

    if (m0_fom_phase(fom) != M0_FOPH_TYPE_SPECIFIC) {
        note = m0_fop_data(fom->fo_fop);

        fom_obj->fp_note.nv_nr = note->nv_nr;
        M0_ALLOC_ARR(fom_obj->fp_note.nv_note, note->nv_nr);
        memcpy( fom_obj->fp_note.nv_note
              , note->nv_note
              , note->nv_nr * sizeof(note->nv_note[0])
              );

        m0_fom_phase_set(fom, M0_FOPH_TYPE_SPECIFIC);
        ha_state_cbs.ha_state_get(&fom_obj->fp_note);
    } else {
        note                         = &fom_obj->fp_note;

        fop_get_rep                  = m0_fop_data(fom->fo_rep_fop);
        fop_get_rep->hs_rc           = fom_obj->fp_rc;
        fop_get_rep->hs_note.nv_nr   = note->nv_nr;

        M0_ALLOC_ARR(fop_get_rep->hs_note.nv_note, note->nv_nr);
        memcpy( fop_get_rep->hs_note.nv_note
              , note->nv_note
              , note->nv_nr * sizeof(*note->nv_note)
              );

        m0_rpc_reply_post(&fom->fo_fop->f_item, &fom->fo_rep_fop->f_item);

        m0_fom_phase_set(fom, M0_FOPH_FINISH);
    }

    return M0_FSO_WAIT;
}

const struct m0_fom_ops ha_state_get_fom_ops = {
    .fo_tick          = ha_state_get_fom_tick,
    .fo_fini          = ha_state_get_fom_fini,
    .fo_home_locality = ha_state_fom_locality,
};

int ha_state_get_fom_create(struct m0_fop *fop, struct m0_fom **m,
                            struct m0_reqh *reqh)
{
    struct ha_state_get_fom     *fom_obj;
    struct m0_fom               *fom;
    struct m0_fop               *reply;

    M0_PRE(fop != NULL);
    M0_PRE(m != NULL);

    M0_ALLOC_PTR(fom_obj);
    if (fom_obj == NULL)
        return M0_ERR(-ENOMEM);

    fom = &fom_obj->fp_gen;
    reply = m0_fop_reply_alloc(fop, &m0_ha_state_get_rep_fopt);
    if (reply == NULL)
        return M0_ERR(-ENOMEM);
    m0_fom_init(fom, &fop->f_type->ft_fom_type, &ha_state_get_fom_ops,
            fop, reply, reqh);

    *m = fom;
    return 0;
}

const struct m0_fom_type_ops ha_state_get_fom_type_ops = {
    .fto_create = &ha_state_get_fom_create
};


/*
 * Set FOM
 */

void ha_state_set_fom_fini(struct m0_fom *fom)
{
     m0_fom_fini(fom);
     m0_free(fom);
}

int ha_state_set_fom_tick(struct m0_fom *fom)
{
    struct m0_ha_nvec *note;
    int rc;

    m0_fom_block_enter(fom);

    note = m0_fop_data(fom->fo_fop);
    rc = ha_state_cbs.ha_state_set(note);

    m0_fom_block_leave(fom);

    if (rc != 0) {
        M0_LOG(M0_DEBUG,"ha_state_cbs->ha_state_set: %d\n",rc);
    }

    m0_rpc_reply_post(&fom->fo_fop->f_item, &fom->fo_rep_fop->f_item);
    m0_fom_phase_set(fom, M0_FOPH_FINISH);

    return M0_FSO_WAIT;
}

const struct m0_fom_ops ha_state_set_fom_ops = {
     .fo_tick          = &ha_state_set_fom_tick,
     .fo_fini          = &ha_state_set_fom_fini,
     .fo_home_locality = &ha_state_fom_locality,
};

int ha_state_set_fom_create(struct m0_fop *fop, struct m0_fom **m,
                            struct m0_reqh *reqh)
{
    struct m0_fom               *fom;
    struct m0_fop               *reply;
    struct m0_fop_generic_reply *rep;

    M0_PRE(fop != NULL);
    M0_PRE(m != NULL);

    M0_ALLOC_PTR(fom);
    reply = m0_fop_reply_alloc(fop, &m0_fop_generic_reply_fopt);
    if (fom == NULL || reply == NULL) {
        m0_free(fom);
        if (reply != NULL)
            m0_fop_put_lock(reply);
        return -ENOMEM;
    }

    m0_fom_init(fom, &fop->f_type->ft_fom_type, &ha_state_set_fom_ops, fop,
                reply, reqh);

    rep = m0_fop_data(reply);
    rep->gr_rc = 0;
    rep->gr_msg.s_len = 0;
    *m = fom;

    return 0;
}

const struct m0_fom_type_ops ha_state_set_fom_type_ops = {
    .fto_create = &ha_state_set_fom_create
};

/* ENTRYPOINT FOM
 *
 */
void ha_state_entrypoint_fom_fini(struct m0_fom *fom)
{
     m0_fom_fini(fom);
     m0_free(fom);
}

static int ha_entrypoint_get_fom_tick(struct m0_fom *fom)
{
        if (m0_fom_phase(fom) != M0_FOPH_TYPE_SPECIFIC) {
            struct m0_ha_entrypoint_rep *rep_fop;
            rep_fop = m0_fop_data(fom->fo_rep_fop);
            rep_fop->hbp_rc = ha_state_cbs.ha_state_entrypoint(fom, rep_fop);
            m0_fom_phase_set(fom, M0_FOPH_TYPE_SPECIFIC);
        } else {
            m0_fom_phase_set(fom, M0_FOPH_FINISH);
            m0_rpc_reply_post(&fom->fo_fop->f_item, &fom->fo_rep_fop->f_item);
        }
        return M0_FSO_WAIT;
}

const struct m0_fom_ops ha_entrypoint_get_ops = {
	.fo_tick = &ha_entrypoint_get_fom_tick,
	.fo_fini = &ha_state_entrypoint_fom_fini,
	.fo_home_locality = &ha_state_fom_locality,
};

static int ha_entrypoint_fom_create(struct m0_fop *fop,
				    struct m0_fom **m,
				    struct m0_reqh *reqh)
{
	struct m0_fom               *fom;
	struct m0_ha_entrypoint_rep *reply;

	M0_PRE(fop != NULL);
	M0_PRE(m != NULL);

	M0_ALLOC_PTR(fom);
	if (fom == NULL)
		return M0_ERR(-ENOMEM);

	M0_ALLOC_PTR(reply);
	if (reply == NULL) {
		m0_free(fom);
		return M0_ERR(-ENOMEM);
	}

	fom->fo_rep_fop = m0_fop_alloc(&m0_ha_entrypoint_rep_fopt, reply,
				       m0_fop_rpc_machine(fop));
	if (fom->fo_rep_fop == NULL) {
		m0_free(reply);
		m0_free(fom);
		return M0_ERR(-ENOMEM);
	}

	m0_fom_init(fom, &fop->f_type->ft_fom_type, &ha_entrypoint_get_ops,
		    fop, fom->fo_rep_fop, reqh);

	*m = fom;
	return M0_RC(0);
}

const struct m0_fom_type_ops ha_entrypoint_fom_type_ops = {
	.fto_create = &ha_entrypoint_fom_create
};
