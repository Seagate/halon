//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#pragma once

#include <semaphore.h>
#include "rpclite.h"
#include "fop/fom_generic.h"

typedef enum {
      RPC_SENDER_TYPE_CONNECT
    , RPC_SENDER_TYPE_DISCONNECT
    , RPC_SENDER_TYPE_SEND_BLOCKING
    , RPC_SENDER_TYPE_SEND
} rpclite_sender_fom_type;

struct fom_state {
    sem_t completed;
    int rc;
};

/*
 * A fom that executes an RPC call.
 *
 * Since these calls must be done from an m0_thread, this fom
 * allows non-m0_threads to submit these calls to a request handler.
 * */
struct m0_fom_rpclite_sender {
    /** Generic m0_fom object. */
    struct m0_fom fp_gen;

    /// The fom type describes the RPC call to execute
    /// and allow to distinguish the valid case in the union
    /// below.
    rpclite_sender_fom_type type;
    /// fom_st stores the result of executing the RPC call and
    /// the semaphore which indicates completion of the fom.
    /// fom_st survives the fom so it can be used after the fom
    /// has executed.
    struct fom_state* fom_st;

    union {
        struct {
            struct m0_rpc_machine* rpc_machine;
            char* remote_address;
            int timeout_s;
            rpc_connection_t** c;
        } connect;
        struct {
            rpc_connection_t* c;
            int timeout_s;
        } disconnect;
        struct {
            rpc_connection_t* c;
			struct m0_fop* fop;
        } send_blocking;
        struct {
			struct m0_rpc_item* rpc_item;
        } send;
    };
};

/// Initializes static structures describing the type
/// of an m0_fom_rpclite_sender_fom.
void m0_fom_rpclite_sender_type_ini();

/// Creates an m0_fom_rpclite_sender_fom.
int rpclite_sender_fom_create(struct m0_fop *fop, struct m0_fom **m, struct m0_reqh* reqh);
