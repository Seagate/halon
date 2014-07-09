//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#include <stdlib.h>
#include "lib/errno.h"
#include "lib/memory.h"
#include "fop/fom.h"
#include "fop/fop.h"
#include "lib/errno.h"
#include "rpc/rpc.h"
#include "fop/fop_item_type.h"
#include "fop/fom_generic.h"


#include "rpclite.h"
#include "rpclite_sender_fom.h"

extern struct m0_reqh_service_type m0_rpc_service_type;

size_t m0_fom_rpclite_sender_home_locality(const struct m0_fom *fom)
{
	M0_PRE(fom != NULL);

	return (intptr_t)fom;
}

static void m0_fom_rpclite_sender_addb_init(struct m0_fom *fom,
		                       struct m0_addb_mc *mc)
{
	    /**
		 *      * @todo: Do the actual impl, need to set MAGIC, so that
		 *           * m0_fom_init() can pass
		 *                */
	    fom->fo_addb_ctx.ac_magic = M0_ADDB_CTX_MAGIC;
}


/**
 * State function for rpclite request
 */
int m0_fom_rpclite_sender_state(struct m0_fom *fom)
{
    struct m0_rpc_item            *item;
    struct m0_fom_rpclite_sender *fom_obj;

	fom_obj = container_of(fom, struct m0_fom_rpclite_sender, fp_gen);
    switch(fom_obj->type) {
        case RPC_SENDER_TYPE_CONNECT:
            m0_fom_block_enter(fom);
            fom_obj->fom_st->rc =
                rpc_connect_m0_thread(fom_obj->connect.rpc_machine
                                ,fom_obj->connect.remote_address
                                ,fom_obj->connect.timeout_s
                                ,fom_obj->connect.c
                                );
            m0_fom_block_leave(fom);
            break;
         case RPC_SENDER_TYPE_DISCONNECT:
            m0_fom_block_enter(fom);
            fom_obj->fom_st->rc =
                rpc_disconnect_m0_thread(fom_obj->disconnect.c
                                ,fom_obj->disconnect.timeout_s
                                );
            m0_fom_block_leave(fom);
            break;
          case RPC_SENDER_TYPE_SEND_BLOCKING:
            m0_fom_block_enter(fom);
            fom_obj->fom_st->rc =
                rpc_send_blocking_m0_thread(fom_obj->send_blocking.c,fom_obj->send_blocking.fop);
            m0_fom_block_leave(fom);
            break;
         case RPC_SENDER_TYPE_SEND:
            fom_obj->fom_st->rc = m0_rpc_post(fom_obj->send.rpc_item);
            break;
        default:
            fprintf(stderr,"m0_fom_rpclite_sender_state: "
                            "unknown fom type %d!!\n",fom_obj->type);
            exit(1);
    }

    if (fom_obj->fom_st && sem_post(&fom_obj->fom_st->completed)) {
       fprintf(stderr,"m0_fom_rpclite_sender_state: "
                    "sem_post failed\n");
       exit(1);
    }

	m0_fom_phase_set(fom, M0_FOPH_FINISH);

	return M0_FSO_WAIT;
}


const struct m0_fom_ops m0_fom_rpclite_sender_ops;
const struct m0_fom_type_ops m0_fom_rpclite_sender_type_ops;
struct m0_fom_type m0_fom_rpclite_sender_type;

/* Init for rpclite */
int rpclite_sender_fom_create(struct m0_fop *fop, struct m0_fom **m, struct m0_reqh* reqh)
{
    struct m0_fom                *fom;
    struct m0_fom_rpclite_sender *fom_obj;

    M0_PRE(m != NULL);

    fom_obj= m0_alloc(sizeof(struct m0_fom_rpclite_sender));
    if (fom_obj == NULL)
        return -ENOMEM;
	fom = &fom_obj->fp_gen;

	m0_fom_init(fom, &m0_fom_rpclite_sender_type, &m0_fom_rpclite_sender_ops, fop, NULL
				, reqh);
	*m = fom;
	return 0;
}

void m0_rpclite_sender_fom_fini(struct m0_fom *fom)
{
	struct m0_fom_rpclite_sender *fom_obj;

	fom_obj = container_of(fom, struct m0_fom_rpclite_sender, fp_gen);
	m0_fom_fini(fom);
	m0_free(fom_obj);

	return;
}

void m0_fom_rpclite_sender_type_ini() {
    m0_fom_type_init( &m0_fom_rpclite_sender_type
                    , &m0_fom_rpclite_sender_type_ops
                    , &m0_rpc_service_type
                    , &m0_generic_conf);
}


/** Generic ops object for rpclite */
const struct m0_fom_ops m0_fom_rpclite_sender_ops = {
	.fo_fini          = m0_rpclite_sender_fom_fini,
	.fo_tick          = m0_fom_rpclite_sender_state,
	.fo_home_locality = m0_fom_rpclite_sender_home_locality,
	.fo_addb_init     = m0_fom_rpclite_sender_addb_init
};

const struct m0_fom_type_ops m0_fom_rpclite_sender_type_ops = {
	.fto_create = rpclite_sender_fom_create
};



