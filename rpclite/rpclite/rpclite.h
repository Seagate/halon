//
// Copyright (C) 2013 Seagate Technology LLC and/or its Affiliates. Apache License, Version 2.0.
//
// See the accompanying COPYING file for license information.
//

// rpclite is an abstraction layer over RPC
//
// The purpose of this library is to hide all the details of Mero RPC that are
// not necessary for the simplest inter process communication.
//

#pragma once

#include "config.h"
#include "fop/fop.h"
#include "sys/uio.h"


/** Initializes RPC.
 *
 * All rpclite API calls can be used after this call returns successfully.
 *
 * Call this function only once during execution of a program.
 * After rpc_fini() is called, rpc_ini() may be called again.

 * \param persistent_prefix prefix directory for client side database,
 *        empty string for current working directory.
 *
 * \return 0 on success, a non-zero value otherwise
 *
 * */
int rpc_init();

/** Releases any resources allocated by rpc_ini().
 *
 * The effect of all rpclite calls is undefined after rpc_fini() is called
 * (except for rpc_ini()).
 *
 * */
void rpc_fini();


/**
 * Client side calls
 * =================
 * */

/**
 * Endpoints
 * ---------
 *
 * An RPC endpoint allows a client to connect to other processes.
 * It encapsulates state specific to a given local address.
 * */

/// RPC endpoints
typedef struct rpc_endpoint rpc_endpoint_t;

/** Creates an endpoint for the given local RPC address.
 *
 * \param local_address the local RPC address the endpoint will use.
 * \param[out] ep on success holds the created endpoint
 *
 * \return 0 on success, a non-zero value otherwise
 */
int rpc_create_endpoint(char* local_address,rpc_endpoint_t** ep);

/// Frees all resources associated with an endpoint.
void rpc_destroy_endpoint(rpc_endpoint_t* ep);

/// Yields the rpc_machine used by the endpoint.
struct m0_rpc_machine* rpc_get_rpc_machine(rpc_endpoint_t* e);

/**
 * Connections
 * -----------
 *
 * In Mero RPC, a connection has sessions. Each session deals with specific
 * QoS and authentication data.
 *
 * Connections are unidirectional. The messages flow from a sender side to a
 * receiver side.
 *
 * An rpc_connection_t in this API is a Mero RPC connection with one session.
 *
 */

/** RPC connections */
typedef struct rpc_connection rpc_connection_t;


/// Yields the rpc session used by a connection.
struct m0_rpc_session* rpc_get_session(rpc_connection_t* c);

/** Creates an RPC connection.
 *
 * \param e endpoint to use for the connection
 * \param remote_address address of the target endpoint
 * \param timeout_s number of seconds to wait for the connection to be
 *                established.
 * \param[out] c on success holds the created connection
 *
 * \return 0 on success, a non-zero value otherwise
 *
 */
int rpc_connect(rpc_endpoint_t* e,char* remote_address,int timeout_s,rpc_connection_t** c);

/// Like rpc_connect but takes an rpc machine instead of an endpoint.
int rpc_connect_rpc_machine( struct m0_rpc_machine* rpc_machine
                           , char* remote_address
                           , int timeout_s
                           , rpc_connection_t** c);

/** Closes the connection and releases local resources used by the connection.
 *
 * \param c the connection to terminate
 * \param timeout_s the timeout in second to wait for the receiver side to reply.
 *                  There are two replies to expect from the receiver side, and the provided
 *                  value is used for each of them in turn.
 * \return 0 on success, a non-zero value otherwise.
 *
 */
int rpc_disconnect(rpc_connection_t* c,int timeout_s);


/** Releases local resources used by the connection.
 * This is intended to be called on a failed connection only.
 * This call should be avoided if rpc_disconnect was called on the connection.
 *
 * \param c the connection to release
 *
 */
void rpc_release_connection(rpc_connection_t* c);

/// Returns the session associated with a connection.
struct m0_rpc_session* rpc_get_session(rpc_connection_t* c);


/** Status values for RPC operations */
typedef enum { RPC_OK, RPC_TIMEOUT, RPC_FAILED } rpc_status_t;

/** Asynchronously send a message of up to 64Kb.
 *
 * \param c connection to send the message through
 * \param segments an array of possibly discontiguous segments of data to send.
 *                 The data must remain accessible until the reply_callback is called.
 * \param segment_count the amount of segments in the segment array
 * \param reply_callback called when the reply for this message is received
 *                       Pass NULL here if no callback is needed
 * \param ctx a value that will be passed to the callback
 * \param timeout_s amount of seconds to wait for the reply
 *
 * \return 0 on success, a non-zero value otherwise
 *
 */
int rpc_send(rpc_connection_t* c,struct iovec* segments,int segment_count,void (*reply_callback)(rpc_connection_t*,void*,rpc_status_t),void* ctx,int timeout_s);

/** Send a message of up to 64Kb, blocking until a reply is received.
 *
 * \param c connection to send the message through
 * \param segments an array of possibly discontiguous segments of data to send
 * \param segment_count the amount of segments in the segment array
 * \param timeout_s amount of time to wait for the reply
 *
 * \return 0 on success, a non-zero value otherwise
 *
 */
int rpc_send_blocking(rpc_connection_t* c,struct iovec* segments,int segment_count,int timeout_s);

/* Sends a message using the request handler of the connection.
 *
 * This method releases the fop. So don't try to use the fop afterwards!
 *
 * */
int rpc_send_fop_blocking_and_release(rpc_connection_t* c,struct m0_fop* fop,int timeout_s);


/**
 * Receiver side calls
 * ===================
 */


/** A message arrived on the receiver side */
typedef struct rpc_item rpc_item_t;


/** Amount of fragments in the message in bytes */
int rpc_get_fragments_count(rpc_item_t* it);
/** Length of the fragment in bytes */
int rpc_get_fragment_count(rpc_item_t* it,int i);
/** Data of the fragment */
uint8_t* rpc_get_fragment(rpc_item_t* it,int);

/** an identifier of the connection on which the item was received.
 *
 * This is needed for as long as we cannot implement connection context
 * on the server side.
 *
 * Note that RPC may reuse identifiers of closed connections.
 * */
void* rpc_get_connection_id(rpc_item_t* it);


/** Callbacks for the receiver side. */
typedef struct rpc_listen_callbacks {
	void* (*connection_callback)(char* data,int len);
       ///^ Called when a connection is created. No receive_callback
       /// corresponding to this connection is called before this callback
       /// returns.
	   ///
	   /// \return a pointer that will be passed as the ctx argument of the other callbacks.

	void (*disconnected_callback)(rpc_status_t status,void* ctx);
       ///^ Called when a connection is destroyed. There are no
       /// receive_callbacks running which correspond to this connection
       /// at the time disconnected_callback is run.
	   ///
	   /// \param status indicates whether the connection was ended by the peer or if there was an error.
	   /// \param ctx the value returned by connection_callback

	int (*receive_callback)(rpc_item_t* it,void* ctx);
       ///^ Called when an item is received. This callback must not block.
	   ///
	   /// \param it the arrived item
	   /// \param ctx the value returned by connection_callback
	   /// \return 0 if the item should be replied and non-zero if it should be ignored

} rpc_listen_callbacks_t;

/** Statistics of various time using for connection and message deliver*/
typedef enum {
	RPC_STAT_CONN,
	RPC_STAT_SEND,
	RPC_STAT_NR,
} rpc_stat_type_t;

typedef struct rpc_statistic {
	struct m0_mutex rs_lock;
	m0_time_t rs_avg_time;
	m0_time_t rs_max_time;
	m0_time_t rs_tot_time;
	uint32_t rs_num;
} rpc_statistic_t;

m0_time_t get_max_rpc_time(rpc_stat_type_t type);
m0_time_t get_avg_rpc_time(rpc_stat_type_t type);
uint32_t get_tot_rpc_num(rpc_stat_type_t type);

/** Starts listening for incoming connections and fops.
 *
 * \param address the address on which the endpoint accepts connections.
 * \param cbs the callbacks this endpoint will use to process connection requests and messages.
 * \param[out] e the created endpoint if the call succeeds.
 *
 * \return 0 on success, a non-zero value otherwise
 *
 * */
int rpc_listen(char* address,rpc_listen_callbacks_t* cbs,rpc_endpoint_t** e);

// internal calls intended for the local request handler

int rpc_connect_m0_thread(struct m0_rpc_machine* rpc_machine,
			  char* remote_address, int timeout_s,
			  rpc_connection_t** c);

int rpc_send_epoch_blocking(rpc_connection_t* c, uint64_t ourEpoch,
                            int timeout_s, uint64_t* theirEpoch);
