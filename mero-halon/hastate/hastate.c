//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//
// This is the hastate interface. It allows to react to request produced by
// mero through the interpretive interface.
//

#define M0_TRACE_SUBSYSTEM M0_TRACE_SUBSYS_HA
#include "lib/trace.h"
#include <stdlib.h>       /* malloc */
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
                          , const struct m0_fid               *profile_fid
                          , const char                        *git_rev_id
                          , bool                               first_request
                          ) {
    ha_state_cbs.ha_state_entrypoint(req_id, process_fid, profile_fid);
}

// Pull out metadata from the m0_ha_msg struct. The user should free
// the memory allocated for the struct.
ha_msg_metadata_t *get_metadata(const struct m0_ha_msg *msg) {
  ha_msg_metadata_t *m = (ha_msg_metadata_t *) malloc(sizeof(ha_msg_metadata_t));
  m->ha_hm_fid = msg->hm_fid;
  m->ha_hm_source_process = msg->hm_source_process;
  m->ha_hm_source_service = msg->hm_source_service;
  m->ha_hm_time = msg->hm_time;
  return m;
}

void msg_received_cb ( struct m0_halon_interface *hi
                     , struct m0_ha_link         *hl
                     , const struct m0_ha_msg    *msg
                     , uint64_t                   tag
                     ) {

    switch (msg->hm_data.hed_type) {
      case M0_HA_MSG_NVEC:
        if (msg->hm_data.u.hed_nvec.hmnv_type)
          ha_state_cbs.ha_state_get( hl
                                   , msg->hm_data.u.hed_nvec.hmnv_id_of_get
                                   , &msg->hm_data.u.hed_nvec);
        else
          ha_state_cbs.ha_state_set(&msg->hm_data.u.hed_nvec);
        break;
      case M0_HA_MSG_EVENT_PROCESS:
        ha_state_cbs.ha_process_event_set( hl
                                         , get_metadata(msg)
                                         , &msg->hm_data.u.hed_event_process);
        break;
      case M0_HA_MSG_EVENT_SERVICE:
        ha_state_cbs.ha_service_event_set ( get_metadata(msg)
                                          , &msg->hm_data.u.hed_event_service);
        break;
      case M0_HA_MSG_BE_IO_ERR:
        ha_state_cbs.ha_be_error( get_metadata(msg)
                                , &msg->hm_data.u.hed_be_io_err);
        break;
      case M0_HA_MSG_FAILURE_VEC_REQ:
        ha_state_cbs.ha_state_failure_vec( hl
                                         , &msg->hm_data.u.hed_fvec_req.mfq_cookie
                                         , &msg->hm_data.u.hed_fvec_req.mfq_pool);
        break;
      case M0_HA_MSG_KEEPALIVE_REP:
        ha_state_cbs.ha_process_keepalive_reply ( hl );
        break;
      default:
        M0_LOG(M0_ALWAYS, "Unknown msg type: %"PRIu64, msg->hm_data.hed_type);
    }
    m0_halon_interface_delivered(m0init_hi, hl, msg);
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
                 , const struct m0_fid *profile_fid
                 , const struct m0_fid *rm_fid
                 , ha_state_callbacks_t *cbs) {
    ha_state_cbs = *cbs;

    return m0_halon_interface_start( m0init_hi, local_rpc_endpoint
                                   , process_fid
                                   , profile_fid
                                   , rm_fid
                                   , entrypoint_request_cb
                                   , msg_received_cb
                                   , msg_is_delivered_cb
                                   , msg_is_not_delivered_cb
                                   , link_connected_cb
                                   , link_reused_cb
                                   , link_is_disconnecting_cb
                                   , link_disconnected_cb
                                   );
}

// Finalizes the ha_state interface.
void ha_state_fini() {
    m0_halon_interface_stop(m0init_hi);
}

/// Notifies mero through the given link that the state of some objects has changed.
uint64_t ha_state_notify(struct m0_ha_link *hl, struct m0_ha_msg_nvec *note) {
    uint64_t tag;
    struct m0_ha_msg msg = (struct m0_ha_msg){
        .hm_fid            = M0_FID_INIT(0, 0),
        .hm_source_process = M0_FID_INIT(0, 0),
        .hm_source_service = M0_FID_INIT(0, 0),
        .hm_time           = m0_time_now(),
        .hm_data = { .hed_type = M0_HA_MSG_NVEC
                   , .u.hed_nvec = *note
                   },
        };

    m0_halon_interface_send(m0init_hi, hl, &msg, &tag);
    return tag;
}


// Sends a failure vector reply back to mero.
uint64_t ha_state_failure_vec_reply(struct m0_ha_link *hl, struct m0_ha_msg_failure_vec_rep *fvec) {
    uint64_t tag;
    struct m0_ha_msg msg = (struct m0_ha_msg){
        .hm_fid            = M0_FID_INIT(0, 0),
        .hm_source_process = M0_FID_INIT(0, 0),
        .hm_source_service = M0_FID_INIT(0, 0),
        .hm_time           = m0_time_now(),
        .hm_data = { .hed_type = M0_HA_MSG_FAILURE_VEC_REP
                   , .u.hed_fvec_rep = *fvec
                   },
        };

    m0_halon_interface_send(m0init_hi, hl, &msg, &tag);
    return tag;
}

uint64_t ha_state_ping_process(struct m0_ha_link *hl, struct m0_uint128 *req_id) {
  uint64_t tag;
  struct m0_ha_msg msg = (struct m0_ha_msg){
    .hm_fid            = M0_FID_INIT(0, 0),
    .hm_source_process = M0_FID_INIT(0, 0),
    .hm_source_service = M0_FID_INIT(0, 0),
    .hm_time           = m0_time_now(),
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

struct m0_rpc_machine * ha_state_rpc_machine() {
    return m0_halon_interface_rpc_machine(m0init_hi);
}
