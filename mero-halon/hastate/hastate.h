//
// Copyright (C) 2012 Xyratex Technology Limited. All rights reserved.
//
// See the accompanying COPYING file for license information.
//
// This is the hastate interface. It allows to react to request produced by
// mero through the interpretive interface.
//

#pragma once

#include "rpclite.h"
#include "ha/note.h"

/// Callbacks for handling requests made with m0_ha_state_get and m0_ha_state_set.
typedef struct ha_state_callbacks {

	/**
	 * Called when a request to get the state of some objects is received.
     * This is expected to happen when mero calls m0_ha_state_get(...).
	 *
	 * When the requested state is available, ha_state_get_done must be called
     * by passing the same note parameter and 0. If there is an error and
	 * the state could not be retrieved then NULL and an error code should be
     * provided.
	 *
	 * If the vector contains at least one invalid indentifier, the error code
	 * should be -EINVAL (or -EKEYREJECTED, or -ENOKEY ?).
	 * */
	void (*ha_state_get)( struct m0_ha_nvec *note);

	/**
	 * Called when a request to update the state of some objects is received.
     * This is expected to happen when mero calls m0_ha_state_set(...).
	 *
	 * \return 0 if the request was accepted or an error code otherwise.
	 * */
	int (*ha_state_set)(struct m0_ha_nvec *note);

        /**
         * Called when a request to read confd and rm service state is received.
         * \return 0 if the request was accepted negative value otherwise
         */
	int (*ha_state_entrypoint)(struct m0_fom *fom, struct m0_ha_entrypoint_rep *rep_fop);
} ha_state_callbacks_t;

/**
 * Indicates that a request initiated with ha_state_get is complete.
 *
 * It takes the state vector carrying the reply and the return code of the
 * request.
 * */
void ha_state_get_done(struct m0_ha_nvec *note,int rc);

/**
 * Registers ha_state_callbacks so they are used when requests arrive.
 * This must be called before m0_init.
 *
 * This call only has an effect if the calling process is going to listening for
 * incoming RPC connections (to be setup with rpclite or some other
 * interface to RPC).
 * */
int ha_state_init(ha_state_callbacks_t *cbs);

// Finalizes the ha_state interface.
void ha_state_fini();

/// Notifies mero at the remote address that the state of some objects has changed.
int ha_state_notify( rpc_endpoint_t *ep, char *remote_address
                   , struct m0_ha_nvec *note, int timeout_s
                   );

// Populates m0_ha_entrypoint_rep structure by values from haskell world.
void ha_entrypoint_reply_wakeup( struct m0_fom               *fom
                               , struct m0_ha_entrypoint_rep *rep_fop
                               , const int                    rc
                               , const int                    confd_fid_size
                               , const struct m0_fid         *confd_fid_data
                               , const int                    confd_eps_size
                               , const char *                *confd_eps_data
                               , const struct m0_fid         *rm_fid
                               , const char *                 rm_eps
                               );
