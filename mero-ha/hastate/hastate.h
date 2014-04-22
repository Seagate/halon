//
// Copyright (C) 2012 Xyratex Technology Limited. All rights reserved.
//
// See the accompanying COPYING file for license information.
//
// This is the hastate interface. It allows to react to request produced by
// mero through the interpretive interface.
//

#pragma once

#include "ha/note.h"
#include "rpclite.h"

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
 *
 * This call only has an effect if the calling process is listening for
 * incoming RPC connections (to be setup with rpclite or some other
 * interface to RPC).
 * */
int ha_state_init(ha_state_callbacks_t *cbs);

// Finalizes the ha_state interface.
void ha_state_fini();

/// Notifies mero at the remote address that the state of some objects has changed.
int ha_state_notify( rpc_receive_endpoint_t *ep, char *remote_address
                   , struct m0_ha_nvec *note, int timeout_s
                   );

