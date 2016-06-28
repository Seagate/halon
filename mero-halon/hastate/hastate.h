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
#include "ha/msg.h"
#include "ha/note.h"
#include "ha/halon/interface.h"

/// Callbacks for handling requests made with m0_ha_state_get and m0_ha_state_set.
typedef struct ha_state_callbacks {

	/**
	 * Called when a request to get the state of some objects is received.
	 * This is expected to happen when mero calls m0_ha_state_get(...).
	 *
	 * When the requested state is available, ha_state_notify must be called
	 * on the given link by passing the same note parameter and 0.
	 * */
	void (*ha_state_get)(struct m0_ha_link *hl, uint64_t idx, const struct m0_ha_msg_nvec *note);

	/**
	 * Called when a request to update the state of some objects is received.
	 * This is expected to happen when mero calls m0_ha_state_set(...).
	 */
	void (*ha_state_set)(const struct m0_ha_msg_nvec *note);

	/**
	 * Called when a request to read confd and rm service state is received.
	 */
	void (*ha_state_entrypoint)( const struct m0_uint128 *req_id
                                   , const struct m0_fid *process_fid
                                   , const struct m0_fid *profile_fid
                                   );

	/**
	 * Called when a new link is connected. The link is alive until
	 * ha_state_disconnect(..) is called.
	 */
	void (*ha_state_link_connected)(struct m0_ha_link *hl);

	/**
	 * The link is no longer needed by the remote peer.  
	 * It is safe to call ha_state_disconnect(..) when all ha_state_notify
	 * calls using the link have completed.
	 */
	void (*ha_state_link_disconnecting)(struct m0_ha_link *hl);

} ha_state_callbacks_t;

/**
 * Registers ha_state_callbacks so they are used when requests arrive at the
 * given local rpc endpoint.
 * */
int ha_state_init( const char *local_rpc_endpoint
                 , const struct m0_fid *process_fid
                 , const struct m0_fid *profile_fid
                 , ha_state_callbacks_t *cbs);

// Finalizes the ha_state interface.
void ha_state_fini();

/// Notifies mero through the given link that the state of some objects has
/// changed. Returns the tag of the message.
uint64_t ha_state_notify(struct m0_ha_link *hl, struct m0_ha_msg_nvec *note);

/// Disconnects a link. It is only safe to call after a ha_state_disconnecting
/// callback for the link is executed and no `ha_state_notify` calls are
/// executing.
void ha_state_disconnect(struct m0_ha_link *hl);

// Populates m0_ha_entrypoint_rep structure by values from haskell world.
void ha_entrypoint_reply( const struct m0_uint128     *req_id
                        , const int                    rc
                        , const int                    confd_fid_size
                        , const struct m0_fid         *confd_fid_data
                        , const int                    confd_eps_size
                        , const char *                *confd_eps_data
                        , const struct m0_fid         *rm_fid
                        , const char *                 rm_eps
                        );

/// Yield the rpc machine created by ha_state_init().
struct m0_rpc_machine * ha_state_rpc_machine();
