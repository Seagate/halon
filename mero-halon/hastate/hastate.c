//
// Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//
// This is the hastate interface. It allows to react to request produced by
// mero through the interpretive interface.
//

#define M0_TRACE_SUBSYSTEM M0_TRACE_SUBSYS_HA
#include "lib/trace.h"
#include "lib/memory.h"
#include "hastate.h"
#include "m0init.h"       /* m0init_hi */
#include "ha/halon/interface.h"


// Holds the callbacks.
// We allow only one instance of the interface per process.
ha_state_callbacks_t ha_state_cbs;

void entrypoint_request_cb( struct m0_halon_interface         *hi
                          , const struct m0_uint128           *req_id
                          , const char             *remote_rpc_endpoint
                          , const struct m0_fid               *process_fid
                          , const char                        *git_rev_id
                          , uint64_t                           pid
                          , bool                               first_request
                          ) {
    ha_state_cbs.ha_state_entrypoint(req_id, process_fid);
}

void msg_received_cb ( struct m0_halon_interface *hi
                     , struct m0_ha_link         *hl
                     , const struct m0_ha_msg    *msg
                     , uint64_t                   tag
                     ) {
    ha_state_cbs.ha_message_callback(hl, msg);
}

void msg_is_delivered_cb ( struct m0_halon_interface *hi
                         , struct m0_ha_link         *hl
                         , uint64_t                   tag
                         ) {
  ha_state_cbs.ha_state_is_delivered(hl, tag);
}

void msg_is_not_delivered_cb ( struct m0_halon_interface *hi
                             , struct m0_ha_link         *hl
                             , uint64_t                   tag
                             ) {
  ha_state_cbs.ha_state_is_cancelled(hl, tag);
}

void link_connected_cb ( struct m0_halon_interface *hi
                       , const struct m0_uint128   *req_id
                       , struct m0_ha_link         *link
                       ) {
    ha_state_cbs.ha_state_link_connected(req_id, link);
}

void link_reused_cb ( struct m0_halon_interface *hi
                    , const struct m0_uint128   *req_id
                    , struct m0_ha_link         *link
                    ) {
    ha_state_cbs.ha_state_link_reused(req_id, link);
}

void link_absent_cb ( struct m0_halon_interface *hi
                    , const struct m0_uint128   *req_id
                    ) {
    ha_state_cbs.ha_state_link_absent(req_id);
}

void link_is_disconnecting_cb ( struct m0_halon_interface *hi
                              , struct m0_ha_link         *link
                              ) {
    ha_state_cbs.ha_state_link_disconnecting(link);
}

void link_disconnected_cb ( struct m0_halon_interface *hi
                          , struct m0_ha_link         *link
                          ) {
    ha_state_cbs.ha_state_link_disconnected(link);
}

// Initializes the ha_state interface.
int ha_state_init( const char *local_rpc_endpoint
                 , const struct m0_fid *process_fid
                 , const struct m0_fid *ha_service_fid
                 , const struct m0_fid *rm_service_fid
                 , ha_state_callbacks_t *cbs) {
    ha_state_cbs = *cbs;

    return m0_halon_interface_start( m0init_hi
				   , local_rpc_endpoint
                                   , process_fid
                                   , ha_service_fid
                                   , rm_service_fid
                                   , entrypoint_request_cb
                                   , msg_received_cb
                                   , msg_is_delivered_cb
                                   , msg_is_not_delivered_cb
                                   , link_connected_cb
                                   , link_reused_cb
                                   , link_absent_cb
                                   , link_is_disconnecting_cb
                                   , link_disconnected_cb
                                   );
}

// Finalizes the ha_state interface.
void ha_state_fini() {
    m0_halon_interface_stop(m0init_hi);
}

/// Notifies mero through the given link that the state of some objects has changed.
uint64_t ha_state_notify( struct m0_ha_link *hl, struct m0_ha_msg_nvec *note
                        , const struct m0_fid *src_process_fid
                        , const struct m0_fid *src_service_fid
                        , uint64_t epoch
                        ) {
    uint64_t tag;
    struct m0_ha_msg msg = (struct m0_ha_msg){
        /* We don't include hm_fid because we're (usually) not talking
           about any one object in particular */
        .hm_fid            = M0_FID_INIT(0, 0),
        .hm_source_process = *src_process_fid,
        .hm_source_service = *src_service_fid,
        .hm_time           = m0_time_now(),
        .hm_epoch          = epoch,
        .hm_data = { .hed_type = M0_HA_MSG_NVEC
                   , .u.hed_nvec = *note
                   },
        };

    m0_halon_interface_send(m0init_hi, hl, &msg, &tag);
    return tag;
}


// Sends a failure vector reply back to mero.
uint64_t ha_state_failure_vec_reply( struct m0_ha_link *hl, struct m0_ha_msg_failure_vec_rep *fvec
                                   , const struct m0_fid *src_process_fid
                                   , const struct m0_fid *src_service_fid ) {
    uint64_t tag;
    struct m0_ha_msg msg = (struct m0_ha_msg){
        .hm_fid            = fvec->mfp_pool,
        .hm_source_process = *src_process_fid,
        .hm_source_service = *src_service_fid,
        .hm_time           = m0_time_now(),
        .hm_epoch          = 'f',  // dummy epoch
        .hm_data = { .hed_type = M0_HA_MSG_FAILURE_VEC_REP
                   , .u.hed_fvec_rep = *fvec
                   },
        };

    m0_halon_interface_send(m0init_hi, hl, &msg, &tag);
    return tag;
}

uint64_t ha_state_ping_process( struct m0_ha_link *hl, struct m0_uint128 *req_id
                              , const struct m0_fid *process_fid
                              , const struct m0_fid *src_process_fid
                              , const struct m0_fid *src_service_fid ) {
  uint64_t tag;
  struct m0_ha_msg msg = (struct m0_ha_msg){
    .hm_fid            = *process_fid,
    .hm_source_process = *src_process_fid,
    .hm_source_service = *src_service_fid,
    .hm_time           = m0_time_now(),
    .hm_epoch          = 'p',  // dummy epoch
    .hm_data = { .hed_type = M0_HA_MSG_KEEPALIVE_REQ
               , .u.hed_keepalive_req.kaq_id = *req_id
               },
  };

  m0_halon_interface_send(m0init_hi, hl, &msg, &tag);
  return tag;
}

void ha_state_disconnect(struct m0_ha_link *hl) {
    m0_halon_interface_disconnect(m0init_hi, hl);
};

// Replies an entrypoint request.
void ha_entrypoint_reply( const struct m0_uint128     *req_id
                        , const int                    rc
                        , uint32_t                     confd_fid_size
                        , const struct m0_fid         *confd_fid_data
                        , const char *                *confd_eps_data
                        , uint32_t                     confd_quorum
                        , const struct m0_fid         *rm_fid
                        , const char *                 rm_eps
                        ) {
    m0_halon_interface_entrypoint_reply
      ( m0init_hi, req_id, rc, confd_fid_size, confd_fid_data
      , confd_eps_data, confd_quorum, rm_fid, rm_eps
      );
}


void ha_state_delivered( struct m0_ha_link          *hl
                       , const struct m0_ha_msg    *msg) {
    m0_halon_interface_delivered(m0init_hi, hl, msg);
}

struct m0_rpc_machine * ha_state_rpc_machine() {
    return m0_halon_interface_rpc_machine(m0init_hi);
}
