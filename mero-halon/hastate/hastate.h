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
#include "ha/link.h"
#include "ha/halon/interface.h"
#include "stob/ioq_error.h"

// m0_ha_msg without the data or private fields
typedef struct ha_msg_metadata {
  struct m0_fid          ha_hm_fid;            /**< conf object fid */
  struct m0_fid          ha_hm_source_process; /**< source process fid */
  struct m0_fid          ha_hm_source_service; /**< source service fid */
  m0_time_t              ha_hm_time;           /**< event timestamp */
  uint64_t               ha_hm_epoch;          /**< message epoch */
} ha_msg_metadata_t;

/// Callbacks for handling requests made with m0_ha_state_get and m0_ha_state_set.
typedef struct ha_state_callbacks {

  /**
   * Called when a request to read confd and rm service state is received.
   *
   *  * req_id - id of the request, this Id should be used in order to link
   *      entrypoint request to the hastate provided in the
   *      ha_state_link_connected request.
   *  * process_fid - Fid of the remote process that is requesting
   *      entrypoint.
   *
   * For each incoming request it's guarantees that either
   * ha_state_link_connected, ha_state_link_reused or ha_state_link_ansent will
   * be called, so request id is used for making a connection between those
   * callbacks and entrypoint request.
   */
  void (*ha_state_entrypoint)( const struct m0_uint128 *req_id
                                   , const struct m0_fid *process_fid
                                   );

  /**
   * Called when a new link is connected. The link is alive until
   * ha_state_disconnect(..) is called.
   *   * req_id - id of the entrypoint request for this link.
   *   * hl     - created link.
   */
  void (*ha_state_link_connected)(const struct m0_uint128 *req_id, struct m0_ha_link *hl);

  /**
   * Called after an existing link requested entrypoint info. The link is alive until
   * ha_state_disconnect(..) is called.
   *   * req_id - id of the entrypoint request for this link.
   *   * hl     - created link.
   */
  void (*ha_state_link_reused)(const struct m0_uint128 *req_id, struct m0_ha_link *hl);

  /**
   * Called after a process that requested the link can't get it for some reason.
   * Example: the process has been previously declared dead by Halon.
   *   * req_id - id of the entrypoint request for this link.
   */
  void (*ha_state_link_absent)(const struct m0_uint128 *req_id);

  /**
   * The link is no longer needed by the remote peer.
   * It is safe to call ha_state_disconnect(..) when all ha_state_notify
   * calls using the link have completed.
   */
  void (*ha_state_link_disconnecting)(struct m0_ha_link *hl);

  /**
   * The link was finally closed.
   */
  void (*ha_state_link_disconnected)(struct m0_ha_link *hl);

  /**
   * The message on the given link was delivered to the endpoint
   */
  void (*ha_state_is_delivered)(struct m0_ha_link *hl, uint64_t tag);

  /**
   * The message on the given link will never be delivered to the
   * endpoint.
   */
  void (*ha_state_is_cancelled)(struct m0_ha_link *hl, uint64_t tag);

  /**
   * Generic message callback, is run when new message is delivered by ha interface.
   */
  void (*ha_message_callback)(struct m0_ha_link *hl, const struct m0_ha_msg *msg);
} ha_state_callbacks_t;

/**
 * Registers ha_state_callbacks so they are used when requests arrive at the
 * given local rpc endpoint.
 *
 *   * local_rpc_endpoint - endpoint address that HA interface should be
 *       listening on.
 *   * process_fid - Fid of the local HA process.
 * */
int ha_state_init( const char *local_rpc_endpoint
                 , const struct m0_fid *process_fid
                 , const struct m0_fid *ha_service_fid
                 , const struct m0_fid *rm_service_fid
                 , ha_state_callbacks_t *cbs);

// Finalizes the ha_state interface.
void ha_state_fini();

/// Notifies mero through the given link that the state of some objects has
/// changed. Returns the tag of the message.
uint64_t ha_state_notify( struct m0_ha_link *hl, struct m0_ha_msg_nvec *note
                        , const struct m0_fid *src_process_fid
                        , const struct m0_fid *src_service_fid
                        , uint64_t epoch);

/// Notifies mero through the given link that the state of some objects has
/// changed. Returns the tag of the message.
uint64_t ha_state_failure_vec_reply( struct m0_ha_link *hl, struct m0_ha_msg_failure_vec_rep *fvec
                                   , const struct m0_fid *src_process_fid
                                   , const struct m0_fid *src_service_fid );

/// Send a keepalive request on the given link with the given req_id.
/// The req_id is sent back by mero in keepalive reply but unused in
/// halon as we don't care about which particular request on the link
/// the reply is for.
uint64_t ha_state_ping_process(struct m0_ha_link *hl, struct m0_uint128 *req_id
                              , const struct m0_fid *process_fid
                              , const struct m0_fid *src_process_fid
                              , const struct m0_fid *src_service_fid );


/// Disconnects a link. It is only safe to call after a ha_state_disconnecting
/// callback for the link is executed and no `ha_state_notify` calls are
/// executing.
void ha_state_disconnect(struct m0_ha_link *hl);

// Populates m0_ha_entrypoint_rep structure by values from haskell world.
void ha_entrypoint_reply( const struct m0_uint128     *req_id
                        , const int                    rc
                        , const uint32_t               confd_fid_size
                        , const struct m0_fid         *confd_fid_data
                        , const char *                *confd_eps_data
                        , const uint32_t               confd_quorum
                        , const struct m0_fid         *rm_fid
                        , const char *                 rm_eps
                        );

/// Marks messages as delivered.
void ha_state_delivered( struct m0_ha_link         *hl
                       , const struct m0_ha_msg    *msg);

/// Yield the rpc machine created by ha_state_init().
struct m0_rpc_machine * ha_state_rpc_machine();
