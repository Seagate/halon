//
// Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//

#include "rpclite.h"

#include "lib/assert.h"
#include "lib/errno.h"
#include "lib/memory.h"
#include "lib/misc.h" /* M0_SET0 */
#include "lib/thread.h"
#include "lib/time.h"
#include "net/net.h"
#include "rpc/session_fops.h"
#include "rpclite_fop.h"
#include "rpclite_fom.h"
#include "rpc/rpclib.h" /* m0_rpc_server_start */
#include "fop/fop.h"    /* m0_fop_default_item_ops */
#include "fop/fop_item_type.h" /* m0_fop_payload_size */
#include "rpclite_fop_ff.h"

#include "ha/epoch.h"

#include <stdlib.h>

#define ITEM_SIZE_CUSHION 128

enum {
    BUF_LEN            = 128,
    STRING_LEN         = 1024,
    M0_LNET_PORTAL     = 34,
    MAX_RPCS_IN_FLIGHT = 32,
    CLIENT_COB_DOM_ID  = 13,
    CONNECT_TIMEOUT    = 20,
	QUEUE_LEN          = 2,
	MAX_MSG_SIZE       = 1 << 17,
};


static struct m0_net_domain client_net_dom;
static struct m0_ha_domain client_ha_dom;
static uint64_t client_max_epoch;
static rpc_statistic_t rpc_stat[RPC_STAT_NR];

void rpc_stat_init()
{
	int i;

	for(i = 0; i < RPC_STAT_NR; i++) {
		m0_mutex_init(&rpc_stat[i].rs_lock);
	}
}

void rpc_stat_fini()
{
	int i;
	for(i = 0; i < RPC_STAT_NR; i++) {
		m0_mutex_fini(&rpc_stat[i].rs_lock);
	}
}

#define CHECK_RESULT(rc,f,onError) do {\
	rc=f;\
	if (rc) {\
		fprintf(stderr,"%s:%d: %s: %s: %d - %s\n",__FILE__,__LINE__,__func__,#f,rc,strerror(-rc)); \
		onError; \
	}} while (0)

int rpc_init() {
	int rc;

	client_max_epoch = 0;

	rpc_stat_init();

	CHECK_RESULT(rc, rpclite_fop_init(),goto rpc_stat_fini);

	CHECK_RESULT(rc, m0_net_domain_init(&client_net_dom, &m0_net_lnet_xprt),goto fop_fini);

	m0_ha_domain_init(&client_ha_dom, 0);

	return 0;

fop_fini:
		rpclite_fop_fini();
rpc_stat_fini:
		rpc_stat_fini();
	return rc;
}

void rpc_fini() {
  m0_ha_domain_fini(&client_ha_dom);
  m0_net_domain_fini(&client_net_dom);
  rpclite_fop_fini();
  rpc_stat_fini();
}

m0_time_t get_max_rpc_time(rpc_stat_type_t type)
{
	return rpc_stat[type].rs_max_time;
}

m0_time_t get_avg_rpc_time(rpc_stat_type_t type)
{
	return rpc_stat[type].rs_avg_time;
}

uint32_t get_tot_rpc_num(rpc_stat_type_t type)
{
	return rpc_stat[type].rs_num;
}

void add_rpc_stat_record(rpc_stat_type_t type, m0_time_t time)
{
	rpc_statistic_t *rs = &rpc_stat[type];

	m0_mutex_lock(&rs->rs_lock);
	rs->rs_num++;
	rs->rs_tot_time += time;
	if(rs->rs_max_time < time)
		rs->rs_max_time = time;

	rs->rs_avg_time = rs->rs_tot_time / rs->rs_num;
	m0_mutex_unlock(&rs->rs_lock);
}

struct rpc_endpoint {
	char local_address[80];
	struct m0_net_buffer_pool buffer_pool;
	struct m0_rpc_machine rpc_machine;
};

struct m0_rpc_machine* rpc_get_rpc_machine(rpc_endpoint_t* e) {
	return &e->rpc_machine;
}

int rpc_create_endpoint(char* local_address,rpc_endpoint_t** e) {
	struct m0_fid process_fid = M0_FID_TINIT('r', 0, 1);
	M0_ASSERT(e);
	*e = (rpc_endpoint_t*)malloc(sizeof(rpc_endpoint_t));
	int rc;

	M0_ASSERT(strlen(local_address)<80);
	strcpy((*e)->local_address,local_address);

	const uint32_t tms_nr   = 1;
	const uint32_t bufs_nr  = m0_rpc_bufs_nr(M0_NET_TM_RECV_QUEUE_DEF_LEN, tms_nr);

	CHECK_RESULT(rc, m0_rpc_net_buffer_pool_setup(&client_net_dom, &(*e)->buffer_pool, bufs_nr, tms_nr)
				,goto pool_fini);


	struct m0_reqh *reqh = malloc(sizeof(*reqh));;
	M0_ASSERT(reqh != NULL);
	M0_SET0(reqh);
	rc = M0_REQH_INIT(reqh,
			  .rhia_dtm          = (void*)1,
			  .rhia_mdstore      = (void*)1,
			  .rhia_fid          = &process_fid);
	if (rc != 0)
		goto pool_fini;
	m0_reqh_start(reqh);

	CHECK_RESULT(rc, m0_rpc_machine_init(&(*e)->rpc_machine,
					     &client_net_dom,
					     (*e)->local_address, reqh,
					     &(*e)->buffer_pool,
					     M0_BUFFER_ANY_COLOUR,
					     MAX_MSG_SIZE, QUEUE_LEN),
		     goto pool_fini);

	return 0;

pool_fini:
		m0_rpc_net_buffer_pool_cleanup(&(*e)->buffer_pool);

	return rc;
}

void rpc_destroy_endpoint(rpc_endpoint_t* e) {
	struct m0_reqh *reqh = e->rpc_machine.rm_reqh;

	m0_rpc_machine_fini(&e->rpc_machine);
	m0_reqh_services_terminate(reqh);
	m0_reqh_fini(reqh);
	free(reqh);
	m0_rpc_net_buffer_pool_cleanup(&e->buffer_pool);
	free(e);
}

struct rpc_connection {
	char remote_address[80];
	struct m0_net_end_point* remote_ep;
	struct m0_rpc_conn connection;
	struct m0_rpc_session session;
};

struct m0_rpc_session* rpc_get_session(rpc_connection_t* c) {
    return &c->session;
}


/*
 * Establishing connections must be done from an m0_thread.
 *
 * An alternative to create connections from non-m0_threads is to call
 * rpc_connect_re.
 *
 * */
int rpc_connect_rpc_machine(struct m0_rpc_machine* rpc_machine, char* remote_address, int timeout_s,
		rpc_connection_t** c) {
	m0_time_t time;
	int rc;
	M0_ASSERT(c);

	time = m0_time_now();

	*c = (rpc_connection_t*)malloc(sizeof(rpc_connection_t));
	M0_ASSERT(strlen(remote_address)<80);
	strcpy((*c)->remote_address,remote_address);

	CHECK_RESULT(rc, m0_net_end_point_create(&(*c)->remote_ep,&rpc_machine->rm_tm, (*c)->remote_address)
			, return rc);

	rc = m0_rpc_conn_create(&(*c)->connection, NULL, (*c)->remote_ep
				, rpc_machine,  MAX_RPCS_IN_FLIGHT, m0_time_from_now(timeout_s,0));
	m0_net_end_point_put((*c)->remote_ep);

	if (!rc) {
		time = m0_time_sub(m0_time_now(), time);
		add_rpc_stat_record(RPC_STAT_CONN, time);
	} else {
		return rc;
	}


	CHECK_RESULT(rc, m0_rpc_session_create(&(*c)->session
						, &(*c)->connection, m0_time_from_now(timeout_s,0))
			,goto conn_destroy);

	return rc;

conn_destroy:
	m0_rpc_conn_destroy(&(*c)->connection, timeout_s);
	return rc;

}

/*
 * Establishing connections must be done from an m0_thread.
 *
 * An alternative to create connections from non-m0_threads is to call
 * rpc_connect_re.
 *
 * */
int rpc_connect(rpc_endpoint_t* e, char* remote_address, int timeout_s,
		rpc_connection_t** c) {
	return rpc_connect_rpc_machine(&e->rpc_machine, remote_address, timeout_s, c);
}


int client_fini(struct m0_rpc_client_ctx *cctx,int timeout_s)
{
	int rc;

	rc = m0_rpc_session_destroy(&cctx->rcx_session, timeout_s);
	rc = m0_rpc_conn_destroy(&cctx->rcx_connection, timeout_s);
	m0_rpc_machine_fini(&cctx->rcx_rpc_machine);
	m0_rpc_net_buffer_pool_cleanup(&cctx->rcx_buffer_pool);

	return rc;
}

int rpc_disconnect(rpc_connection_t* c,int timeout_s) {
  int rc;
  CHECK_RESULT(rc, m0_rpc_session_destroy(&c->session, M0_TIME_NEVER), );
  CHECK_RESULT(rc, m0_rpc_conn_destroy(&c->connection, M0_TIME_NEVER), );
  // m0_net_end_point_put(c->remote_ep);

  free(c);
  return rc;
}

void rpc_release_connection(rpc_connection_t* c) {
	m0_rpc_session_fini(&c->session);
	m0_rpc_conn_fini(&c->connection);
	// m0_net_end_point_put(c->remote_ep);

	free(c);
}

rpc_listen_callbacks_t rpclite_listen_cbs;

int rpc_listen(char* address,rpc_listen_callbacks_t* cbs,rpc_endpoint_t** e) {

	if (cbs) {
		rpclite_listen_cbs = *cbs;
	} else {
		rpclite_listen_cbs = (rpc_listen_callbacks_t)
			{ .connection_callback=NULL
			, .disconnected_callback=NULL
			, .receive_callback=NULL
			};
	}

    return rpc_create_endpoint(address,e);
}

static void fill_rpclite_fop(struct rpclite_fop* rpclite_fop,
			     struct iovec* segments,
			     int segment_count)
{
    int i;
	//struct rpclite_fop_fragment* fr;
    int sum=0;
    for(i=0;i<segment_count;i+=1)
        sum += segments[i].iov_len;
	rpclite_fop->fp_fragments.f_count = sum;

	M0_ALLOC_ARR(rpclite_fop->fp_fragments.f_fragments, sum);
	M0_ASSERT(rpclite_fop->fp_fragments.f_fragments != NULL);

    int offset=0;
    for(i=0;i<segment_count;i+=1) {
        memcpy(rpclite_fop->fp_fragments.f_fragments+offset,segments[i].iov_base,segments[i].iov_len);
        offset+=segments[i].iov_len;
    }

    /*
	rpclite_fop->fp_fragments.f_count = segment_count;

	M0_ALLOC_ARR(rpclite_fop->fp_fragments.f_fragments, segment_count);
	M0_ASSERT(rpclite_fop->fp_fragments.f_fragments != NULL);

	fr = rpclite_fop->fp_fragments.f_fragments;
	for (i = 0; i < segment_count; i+=1) {
		fr->f_data = segments[i].iov_base;
		fr->f_count = segments[i].iov_len;
		fr+=1;
	}
    */
}

/* Sends a message using the request handler of the connection.
 *
 * This method releases the fop. So don't try to use the fop afterwards!
 *
 * */
int rpc_send_fop_blocking_and_release(rpc_connection_t* c,struct m0_fop* fop,int timeout_s) {
	int rc;

	M0_ASSERT(fop != NULL);
    if (m0_fop_payload_size(&fop->f_item)+ITEM_SIZE_CUSHION > m0_rpc_session_get_max_item_size(&c->session)) {
        fprintf(stderr,"rpc_send_fop_blocking_and_release: rpclite got a message which is too big"
                       ": %d vs %d\n", (int)m0_fop_payload_size(&fop->f_item)
                                     , (int)m0_rpc_session_get_max_item_size(&c->session)-ITEM_SIZE_CUSHION
               );
        exit(1);
    }

	fop->f_item.ri_nr_sent_max = 1;
	fop->f_item.ri_resend_interval = m0_time(timeout_s?timeout_s:1,0);

	rc = m0_rpc_post_sync(fop, &c->session, NULL, m0_time_from_now(0,1*1000*1000));

        if (!rc) {
          M0_ASSERT(rc == 0);
          M0_ASSERT(fop->f_item.ri_error == 0);
          M0_ASSERT(fop->f_item.ri_reply != 0);
        }

        m0_fop_put_lock(fop);

	return rc;
}

/* Sends a message using the request handler of the connection. */
int rpc_send_blocking(rpc_connection_t* c,struct iovec* segments,int segment_count,int timeout_s) {
	struct m0_fop      *fop;
	struct rpclite_fop* rpclite_fop;
	int rc;

	fop = m0_fop_alloc_at(&c->session, &m0_fop_rpclite_fopt);
	M0_ASSERT(fop != NULL);

	rpclite_fop = m0_fop_data(fop);
    fill_rpclite_fop(rpclite_fop,segments,segment_count);

    rc = rpc_send_fop_blocking_and_release(c,fop,timeout_s);

	return rc;
}

int rpc_get_fragments_count(rpc_item_t* it) {
    return 1;
	// return ((struct rpclite_fop*)m0_fop_data(it->fop))->fp_fragments.f_count;
}

int rpc_get_fragment_count(rpc_item_t* it,int i){
	return ((struct rpclite_fop*)m0_fop_data(it->fop))->fp_fragments.f_count;
	// return ((struct rpclite_fop*)m0_fop_data(it->fop))->fp_fragments.f_fragments[i].f_count;
}

uint8_t* rpc_get_fragment(rpc_item_t* it,int i) {
	return ((struct rpclite_fop*)m0_fop_data(it->fop))->fp_fragments.f_fragments;
	// return ((struct rpclite_fop*)m0_fop_data(it->fop))->fp_fragments.f_fragments[i].f_data;
}

void* rpc_get_connection_id(rpc_item_t* it) {
    return it->fop->f_item.ri_session;
}


// A special FOP container is necessary to make callbacks with
// parameters supplied to rpc_send.
typedef struct rpclite_senderside_message {
	rpc_connection_t* c;
	void* ctx;
	void (*reply_callback)(rpc_connection_t*,void*,rpc_status_t);
	struct m0_fop fop;
	m0_time_t ctime;
} rpclite_senderside_message_t;

void rpclite_replied(struct m0_rpc_item* item) {
	rpclite_senderside_message_t* msg = container_of(item, rpclite_senderside_message_t, fop.f_item);
	rpc_status_t st;
	m0_time_t time;

	switch(-msg->fop.f_item.ri_error) {
		case ETIMEDOUT:
			st = RPC_TIMEOUT;
			break;
		case 0:
			st = RPC_OK;
			time = m0_time_now() - msg->ctime;
			add_rpc_stat_record(RPC_STAT_SEND, time);
			break;
		default:
			fprintf(stderr,"%s error: %d",__func__,msg->fop.f_item.ri_error);
			st = RPC_FAILED;
	}
	msg->reply_callback(msg->c,msg->ctx,st);
    m0_fop_put(&msg->fop);
}

// A routine for freeing rpclite_senderside_message_t memory
void rpclite_senderside_free_nonuser_memory(struct m0_ref* ref) {
	struct m0_fop *fop = container_of(ref, struct m0_fop, f_ref);

	//struct rpclite_fop* rpclite_fop = m0_fop_data(fop);
	//m0_free(rpclite_fop->fp_fragments.f_fragments);
	//m0_free(fop->f_data.fd_data);
	//fop->f_data.fd_data = NULL;
	m0_fop_fini(fop);
	m0_free(container_of(fop, rpclite_senderside_message_t, fop));
}

const struct m0_rpc_item_ops item_ops = {
			.rio_replied = rpclite_replied,
};


/*
 * Sends a message from the current thread if the connection was not
 * created with a request handler, otherwise, it uses the request handler
 * to send the message.
 * */
int rpc_send(rpc_connection_t* c,struct iovec* segments,int segment_count,void (*reply_callback)(rpc_connection_t*,void*,rpc_status_t),void* ctx,int timeout_s) {
	rpclite_senderside_message_t* msg;
	struct rpclite_fop* rpclite_fop;
	int rc;

	M0_ALLOC_PTR(msg);
	if (msg != NULL) {
		msg->ctime = m0_time_now();
		m0_fop_init(&msg->fop, &m0_fop_rpclite_fopt, NULL, rpclite_senderside_free_nonuser_memory);
		msg->fop.f_item.ri_session = &c->session;
		msg->fop.f_item.ri_deadline = m0_time_from_now(0,1*1000*1000);
		msg->fop.f_item.ri_nr_sent_max = 1;
		msg->fop.f_item.ri_resend_interval = m0_time(timeout_s?timeout_s:1,0);
		msg->fop.f_item.ri_rmachine = m0_fop_session_machine(&c->session);
		msg->ctx = ctx;
		msg->c = c;
		msg->fop.f_item.ri_ops = &item_ops;
		msg->fop.f_item.ri_prio = M0_RPC_ITEM_PRIO_MID;
		msg->reply_callback = reply_callback;
		CHECK_RESULT(rc, m0_fop_data_alloc(&msg->fop), m0_free(msg); return rc;);
	}
	M0_ASSERT(msg != NULL);


	rpclite_fop = m0_fop_data(&msg->fop);
    fill_rpclite_fop(rpclite_fop,segments,segment_count);

    if (m0_fop_payload_size(&msg->fop.f_item)+ITEM_SIZE_CUSHION > m0_rpc_session_get_max_item_size(&c->session)) {
        fprintf(stderr,"rpc_send: rpclite got a message which is too big"
                       ": %d vs %d\n", (int)m0_fop_payload_size(&msg->fop.f_item)
                                     , (int)m0_rpc_session_get_max_item_size(&c->session)-ITEM_SIZE_CUSHION
               );
exit(1);
    }
	return m0_rpc_post(&msg->fop.f_item);
}

/*
   A modification of rpc_send_blocking() that sends a fop containing an epoch
   field and returns the recepient's epoch if it replies within the given time.
 */
int rpc_send_epoch_blocking(rpc_connection_t* c, uint64_t ourEpoch,
                            int timeout_s, uint64_t* theirEpoch) {
  struct m0_fop* fop;
  int            rc;
  struct m0_rpc_fop_session_terminate *fop_data;

  if (client_max_epoch > ourEpoch)
  {
    *theirEpoch = client_max_epoch;
    return 0;
  }
  else
    client_max_epoch = ourEpoch;

  fop = m0_fop_alloc_at(&c->session, &m0_rpc_fop_session_terminate_fopt);
  M0_ASSERT(fop != NULL);

  fop_data = m0_fop_data(fop);
  fop_data->rst_sender_id = c->session.s_session_id;
  fop_data->rst_session_id = -1;

  m0_ha_domain_get_write(&client_ha_dom);
  m0_ha_domain_put_write(&client_ha_dom, ourEpoch);

  rc = rpc_send_fop_blocking_and_release(c,fop,timeout_s);
  if (rc == 0)
  {
    *theirEpoch = m0_ha_domain_get_write(&client_ha_dom);
    m0_ha_domain_put_write(&client_ha_dom, *theirEpoch);
  }

  return rc;
}
