//
// Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//

#include "rpclite_fom.h"
#include "rpclite.h"
#include "rpclite_fop_ff.h"
#include "fop/fop.h"
#include "lib/errno.h"
#include "lib/memory.h"
#include "rpc/rpc.h"
#include "fop/fom_generic.h"


extern rpc_listen_callbacks_t rpclite_listen_cbs;

static int rpclite_fop_fom_create(struct m0_fop *fop, struct m0_fom **m,
									struct m0_reqh* reqh);

/** Generic ops object for rpclite */
struct m0_fom_ops m0_fom_rpclite_ops = {
	.fo_fini          = m0_fop_rpclite_fom_fini,
	.fo_tick          = m0_fom_rpclite_state,
	.fo_home_locality = m0_fom_rpclite_home_locality,
};

/** FOM type specific functions for rpclite FOP. */
const struct m0_fom_type_ops m0_fom_rpclite_type_ops = {
	.fto_create = rpclite_fop_fom_create
};

size_t m0_fom_rpclite_home_locality(const struct m0_fom *fom)
{
	M0_PRE(fom != NULL);

	return m0_fop_opcode(fom->fo_fop);
}

void disconnected_ast(struct m0_sm_group* grp, struct m0_sm_ast* ast) {
    struct m0_clink* link = ast->sa_datum;
	fprintf(stderr,"ast: %p\n",grp);
	m0_clink_del(link);
	m0_clink_fini(link);
	m0_free(link);
    m0_free(ast);
}

bool disconnected_cb(struct m0_clink* link) {
    struct m0_sm* sm = container_of(link->cl_chan,struct m0_sm,sm_chan);
	if (sm->sm_state==M0_RPC_SESSION_TERMINATED) {
		fprintf(stderr,"disconnected %p\n",sm->sm_grp);

//        struct m0_sm_ast* ast;
//        M0_ALLOC_PTR(ast);
//        ast->sa_cb = disconnected_ast;
//        ast->sa_datum = link;
//        m0_sm_ast_post(sm->sm_grp,ast);
	}
	return true;
}

/**
 * State function for rpclite request
 */
int m0_fom_rpclite_state(struct m0_fom *fom)
{
	struct m0_fop			*fop;
        struct rpclite_fop_rep		*rpclite_fop_rep;
        struct m0_rpc_item              *item;

    if (!rpclite_listen_cbs.receive_callback
		|| !rpclite_listen_cbs.receive_callback(&(struct rpc_item){ .fop = fom->fo_fop },NULL)
       ) {
        fop = m0_fop_reply_alloc(fom->fo_fop,&m0_fop_rpclite_rep_fopt);
        M0_ASSERT(fop != NULL);
        rpclite_fop_rep = m0_fop_data(fop);
        rpclite_fop_rep->f_seq = true;
    	item = m0_fop_to_rpc_item(fop);
        m0_rpc_reply_post(&fom->fo_fop->f_item, item);
    }

	m0_fom_phase_set(fom, M0_FOPH_FINISH);

//	struct m0_clink* cl;
//	M0_ALLOC_PTR(cl);
//	m0_clink_init(cl,disconnected_cb);
//	m0_clink_add(&fom->fo_fop->f_item.ri_session->s_sm.sm_chan,cl);

	// m0_rpc_conn_destroy(fom->fo_fop->f_item.ri_session->s_conn,10);

	return M0_FSO_WAIT;
}

// M0_RPC_SESSION_TERMINATED

/* Init for rpclite */
static int rpclite_fop_fom_create(struct m0_fop *fop, struct m0_fom **m, struct m0_reqh* reqh)
{
    struct m0_fom                   *fom;

    M0_PRE(fop != NULL);
    M0_PRE(m != NULL);

    fom = m0_alloc(sizeof(struct m0_fom));
    if (fom == NULL)
        return -ENOMEM;
	m0_fom_init(fom, &fop->f_type->ft_fom_type, &m0_fom_rpclite_ops, fop, NULL
				, reqh);
	*m = fom;
	return 0;
}

void m0_fop_rpclite_fom_fini(struct m0_fom *fom)
{
	m0_fom_fini(fom);
	m0_free(fom);
}

