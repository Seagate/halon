//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#define _GNU_SOURCE
#include "rpclite.h"

#include "mero/init.h"
#include "lib/assert.h"
#include "lib/errno.h"
#include "lib/memory.h"
#include "lib/misc.h" /* M0_SET0 */
#include "lib/thread.h"
#include "lib/time.h"
#include "module/instance.h"
#include "net/net.h"
#include "net/lnet/lnet.h"
#include "rpc/rpc.h"
#include "rpc/session_fops.h"
#include "rpc/session_foms.h"
#include "rpclite_fop.h"
#include "rpclite_fom.h"
#include "rpc/rpclib.h" /* m0_rpc_server_start */
#include "fop/fop.h"    /* m0_fop_default_item_ops */
#include "fop/fop_item_type.h" /* m0_fop_payload_size */
#include "reqh/reqh.h"  /* m0_reqh_rpc_mach_tl */
#include "rpclite_fop_ff.h"

#include "ha/epoch.h"

#include "rpclite_sender_fom.h"

#include <stdlib.h>

#define ITEM_SIZE_CUSHION 128
#define LINUXSTOB_PREFIX "linuxstob:"
#define DB_FILE_NAME     "rpclite.db"
#define S_DB_FILE_NAME     "rpclite2.db"
#define S_STOB_FILE_NAME   "rpclite2.stob"
#define S_ADDB_STOB_FILE_NAME   "rpclite2_addb.stob"
#define S_LOG_FILE_NAME    "rpclite2.log"

enum {
    BUF_LEN            = 128,
    STRING_LEN         = 1024,
    M0_LNET_PORTAL     = 34,
    MAX_RPCS_IN_FLIGHT = 32,
    CLIENT_COB_DOM_ID  = 13,
    CONNECT_TIMEOUT    = 20,
	QUEUE_LEN      = 16,
	MAX_MSG_SIZE       = 1 << 16,
};


static struct m0 instance;
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

int rpc_init(char *persistence_prefix) {
	int rc;
        char client_db[STRING_LEN];

	client_max_epoch = 0;

	rpc_stat_init();

	CHECK_RESULT(rc, m0_init(&instance), return rc);

	CHECK_RESULT(rc, rpclite_fop_init(),goto m0_fini);

	CHECK_RESULT(rc, m0_net_domain_init(&client_net_dom, &m0_net_lnet_xprt),goto fop_fini);

	m0_ha_domain_init(&client_ha_dom, 0);

	M0_ASSERT(strlen(persistence_prefix)+strlen(DB_FILE_NAME)<STRING_LEN);
	strcpy(client_db, persistence_prefix);
	strcat(client_db, DB_FILE_NAME);

	m0_fom_rpclite_sender_type_ini();

	return 0;

net_dom_fini:
		m0_net_domain_fini(&client_net_dom);
ha_fini:
		m0_ha_domain_fini(&client_ha_dom);
fop_fini:
		rpclite_fop_fini();
m0_fini:
		m0_fini();
		rpc_stat_fini();
	return rc;
}

void rpc_fini() {
  m0_ha_domain_fini(&client_ha_dom);
  m0_net_domain_fini(&client_net_dom);
  rpclite_fop_fini();
  m0_fini();
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
			  .rhia_db           = NULL,
			  .rhia_mdstore      = (void*)1);
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

/*
 * Creates a fom that can be submitted to the request handler
 * to perform a specific operation.
 * */
int create_sender_fom(struct m0_fom_rpclite_sender** fom_obj
					, struct m0_reqh* reqh
					, rpclite_sender_fom_type type,struct fom_state* fom_st) {
	struct m0_fom *fom;
	int rc;
	CHECK_RESULT(rc, rpclite_sender_fom_create(NULL,&fom,reqh), return rc);
	*fom_obj = container_of(fom, struct m0_fom_rpclite_sender, fp_gen);

	(*fom_obj)->type = type;
	(*fom_obj)->fom_st = fom_st;

	if (fom_st) {
		fom_st->rc = 0;
		if (sem_init(&fom_st->completed,0,0)) {
			fprintf(stderr,"%s: sem_init failed\n",__func__);
	        exit(1);
		}
	}
	return 0;
}

/*
 * Enqueues a fom to a request handler, then waits for the fom to complete.
 * */
void run_sender_fom(struct m0_fom_rpclite_sender* fom_obj
					, struct m0_reqh* reqh) {
	struct fom_state* fom_st = fom_obj->fom_st;
	m0_fom_queue(&fom_obj->fp_gen, reqh);
	if (fom_st) {
		if (sem_wait(&fom_st->completed)) {
		    fprintf(stderr,"%s: sem_wait failed\n",__func__);
			exit(1);
		}
		if (sem_destroy(&fom_st->completed)) {
		    fprintf(stderr,"%s: sem_destroy failed\n",__func__);
			exit(1);
		}
	}
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

/* Creates an RPC connection. Must be called from an m0_thread. */
int rpc_connect_m0_thread(struct m0_rpc_machine* rpc_machine,
			  char* remote_address, int timeout_s,
			  rpc_connection_t** c) {
	M0_ASSERT(c);
	*c = (rpc_connection_t*)malloc(sizeof(rpc_connection_t));
	int rc;

	M0_ASSERT(strlen(remote_address)<80);
	strcpy((*c)->remote_address,remote_address);

	CHECK_RESULT(rc, m0_net_end_point_create(&(*c)->remote_ep,&rpc_machine->rm_tm, (*c)->remote_address)
				, return rc);

	rc = m0_rpc_conn_create(&(*c)->connection, (*c)->remote_ep
				, rpc_machine,  MAX_RPCS_IN_FLIGHT, m0_time_from_now(timeout_s,0));
	m0_net_end_point_put((*c)->remote_ep);
	if (rc)
		return rc;

	CHECK_RESULT(rc, m0_rpc_session_create(&(*c)->session
					, &(*c)->connection, m0_time_from_now(timeout_s,0))
				,goto conn_destroy);

	return 0;

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
	m0_time_t time;
	int rc;

	time = m0_time_now();
	rc = rpc_connect_m0_thread(&e->rpc_machine,remote_address,timeout_s,c);

	if (!rc) {
		time = m0_time_sub(m0_time_now(), time);
		add_rpc_stat_record(RPC_STAT_CONN, time);
	}
	return rc;
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


int rpc_disconnect_m0_thread(rpc_connection_t* c,int timeout_s) {
	int rc;
	CHECK_RESULT(rc, m0_rpc_session_destroy(&c->session, M0_TIME_NEVER), );
	CHECK_RESULT(rc, m0_rpc_conn_destroy(&c->connection, M0_TIME_NEVER), );
	// m0_net_end_point_put(c->remote_ep);

	free(c);
	return rc;
}

int rpc_disconnect(rpc_connection_t* c,int timeout_s) {
	struct m0_fom *fom;
	int rc;
	struct m0_fom_rpclite_sender *fom_obj;
	struct fom_state fom_st;
	struct m0_reqh *reqh = c->connection.c_rpc_machine->rm_reqh;
	CHECK_RESULT(rc, create_sender_fom(&fom_obj,reqh,RPC_SENDER_TYPE_DISCONNECT,&fom_st), return rc);

	fom_obj->disconnect.c = c;
	fom_obj->disconnect.timeout_s = timeout_s;

	run_sender_fom(fom_obj,reqh);
	return fom_st.rc;

}

void rpc_release_connection(rpc_connection_t* c) {
	m0_rpc_session_fini(&c->session);
	m0_rpc_conn_fini(&c->connection);
	// m0_net_end_point_put(c->remote_ep);

	free(c);
}


struct rpc_receive_endpoint {
	struct m0_rpc_server_ctx sctx;
	char tm_len[STRING_LEN];
	char rpc_size[STRING_LEN];
    char server_endpoint[M0_NET_LNET_XEP_ADDR_LEN];
	char** server_argv;
    char db_file_name[STRING_LEN];
    char stob_file_name[STRING_LEN];
    char addb_stob_file_name[STRING_LEN];
    char log_file_name[STRING_LEN];
};

rpc_listen_callbacks_t rpclite_listen_cbs;

/*
 * Creates a connection by asking an m0_thread managed by the request
 * handler of a receive endpoint to establish the connection.
 * */
int rpc_connect_re(rpc_receive_endpoint_t* e, char* remote_address,
		   int timeout_s,rpc_connection_t** c) {
	M0_ASSERT(c);
	struct m0_fom *fom;
	int rc;
	struct m0_fom_rpclite_sender *fom_obj;
	struct fom_state fom_st;
	m0_time_t time;
	struct m0_reqh* reqh = m0_cs_reqh_get(&e->sctx.rsx_mero_ctx);
	if (!reqh) {
		fprintf(stderr,"%s: could not find request handler.",__func__);
		return 1;
	}

	time = m0_time_now();
	CHECK_RESULT(rc, create_sender_fom(&fom_obj,reqh,RPC_SENDER_TYPE_CONNECT,&fom_st), return rc);

	fom_obj->connect.rpc_machine = m0_mero_to_rmach(&e->sctx.rsx_mero_ctx);
	fom_obj->connect.remote_address = remote_address;
	fom_obj->connect.timeout_s = timeout_s;
	fom_obj->connect.c = c;

	run_sender_fom(fom_obj,reqh);
	if (fom_st.rc==0) {
		time = m0_time_sub(m0_time_now(), time);
		add_rpc_stat_record(RPC_STAT_CONN, time);
	}
	return fom_st.rc;
}

struct m0_rpc_machine* rpc_get_rpc_machine_re(rpc_receive_endpoint_t* e) {
	return m0_mero_to_rmach(&e->sctx.rsx_mero_ctx);
}

int rpc_listen(char* persistence_prefix,char* address,rpc_listen_callbacks_t* cbs,rpc_receive_endpoint_t** re) {

	int rc;
	int i;
	struct m0_net_xprt *xprt = &m0_net_lnet_xprt;

	if (cbs) {
		rpclite_listen_cbs = *cbs;
	} else {
		rpclite_listen_cbs = (rpc_listen_callbacks_t)
			{ .connection_callback=NULL
			, .disconnected_callback=NULL
			, .receive_callback=NULL
			};
	}
	*re = (rpc_receive_endpoint_t*)malloc(sizeof(rpc_receive_endpoint_t));

	strcpy((*re)->server_endpoint,"lnet:");
	M0_ASSERT(strlen(address)+strlen((*re)->server_endpoint)<M0_NET_LNET_XEP_ADDR_LEN);
	strcat((*re)->server_endpoint,address);

	M0_ASSERT(strlen(persistence_prefix)+strlen(S_DB_FILE_NAME)<STRING_LEN);
	strcpy((*re)->db_file_name,persistence_prefix);
	strcat((*re)->db_file_name,S_DB_FILE_NAME);

   	M0_ASSERT(strlen(LINUXSTOB_PREFIX)+strlen(persistence_prefix)+strlen(S_ADDB_STOB_FILE_NAME)<STRING_LEN);
   	strcpy((*re)->addb_stob_file_name, LINUXSTOB_PREFIX);
	strcat((*re)->addb_stob_file_name, persistence_prefix);
	strcat((*re)->addb_stob_file_name, S_ADDB_STOB_FILE_NAME);

   	M0_ASSERT(strlen(persistence_prefix)+strlen(S_STOB_FILE_NAME)<STRING_LEN);
	strcpy((*re)->stob_file_name,persistence_prefix);
	strcat((*re)->stob_file_name,S_STOB_FILE_NAME);

   	M0_ASSERT(strlen(persistence_prefix)+strlen(S_LOG_FILE_NAME)<STRING_LEN);
	strcpy((*re)->log_file_name,persistence_prefix);
	strcat((*re)->log_file_name,S_LOG_FILE_NAME);

    sprintf((*re)->tm_len, "%d" , QUEUE_LEN);
    sprintf((*re)->rpc_size, "%d" , MAX_MSG_SIZE);

	char *server_argv[] = {
	                "rpclib_ut", "-T", "AD", "-D", (*re)->db_file_name,
	                "-S", (*re)->stob_file_name, "-e", (*re)->server_endpoint,
					"-A", (*re)->addb_stob_file_name,"-w","5",
	                "-q", (*re)->tm_len, "-m", (*re)->rpc_size
    };

	(*re)->server_argv = (char**)malloc(sizeof(server_argv));
	for(i=0;i<ARRAY_SIZE(server_argv);i+=1)
		(*re)->server_argv[i] = server_argv[i];

    (*re)->sctx = (struct m0_rpc_server_ctx) {
			                .rsx_xprts            = &xprt,
			                .rsx_xprts_nr         = 1,
			                .rsx_argv             = (*re)->server_argv,
			                .rsx_argc             = ARRAY_SIZE(server_argv),
			                .rsx_log_file_name    = (*re)->log_file_name
			        };

    CHECK_RESULT(rc, m0_rpc_server_start(&(*re)->sctx), free((*re)->server_argv);free(*re) );

	return rc;
}


void rpc_stop_listening(rpc_receive_endpoint_t* re) {
	m0_rpc_server_stop(&re->sctx);
	free(re->server_argv);
	free(re);
}

// We provide our own routine for freeing the the FOP.
// The default m0_fop_free would free the user-suplied
// buffers which are not intended to be owned by the rpc layer.
void rpclite_fop_free_nonuser_memory(struct m0_ref *ref) {
	struct m0_fop *fop = container_of(ref, struct m0_fop, f_ref);
	struct rpclite_fop* rpclite_fop = m0_fop_data(fop);
	int i;
	m0_free(rpclite_fop->fp_fragments.f_fragments);
	m0_free(fop->f_data.fd_data);
	fop->f_data.fd_data = NULL;
	m0_fop_release(ref);
}

inline void fill_rpclite_fop(struct rpclite_fop* rpclite_fop,struct iovec* segments,int segment_count) {
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


int rpc_send_blocking_and_release_m0_thread(rpc_connection_t* c,struct m0_fop* fop) {

	int rc = m0_rpc_post_sync(fop, &c->session, NULL, m0_time_from_now(0,1*1000*1000));
    if (!rc) {
		M0_ASSERT(rc == 0);
	    M0_ASSERT(fop->f_item.ri_error == 0);
		M0_ASSERT(fop->f_item.ri_reply != 0);
    }
    m0_fop_put_lock(fop);

	return rc;
}

/* Sends a message using the request handler of the connection.
 *
 * This method releases the fop. So don't try to use the fop afterwards!
 *
 * */
int rpc_send_fop_blocking_and_release(rpc_connection_t* c,struct m0_fop* fop,int timeout_s) {
	m0_time_t time;
	int rc;

	M0_ASSERT(fop != NULL);
    if (m0_fop_payload_size(&fop->f_item)+ITEM_SIZE_CUSHION > m0_rpc_session_get_max_item_size(&c->session)) {
        fprintf(stderr,"rpc_send_fop_blocking_and_release: rpclite got a message which is too big"
                       ": %d vs %d\n", m0_fop_payload_size(&fop->f_item)
                                     , m0_rpc_session_get_max_item_size(&c->session)-ITEM_SIZE_CUSHION
               );
        exit(1);
    }

	time = m0_time_now();

	fop->f_item.ri_nr_sent_max = 1;
	fop->f_item.ri_resend_interval = m0_time(timeout_s?timeout_s:1,0);

	struct m0_fom *fom;
	struct m0_fom_rpclite_sender *fom_obj;
	struct fom_state fom_st;
	struct m0_reqh *reqh = c->connection.c_rpc_machine->rm_reqh;
	CHECK_RESULT(rc, create_sender_fom(&fom_obj,reqh,RPC_SENDER_TYPE_SEND_BLOCKING,&fom_st), return rc);

	fom_obj->send_blocking.c = c;
	fom_obj->send_blocking.fop = fop;

	run_sender_fom(fom_obj,reqh);
	rc = fom_st.rc;
out:
	if (!rc) {
		time = m0_time_sub(m0_time_now(), time);
		add_rpc_stat_record(RPC_STAT_SEND, time);
	}
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

char* rpc_get_fragment(rpc_item_t* it,int i) {
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
		msg->fop.f_item.ri_nr_sent_max = CONNECT_TIMEOUT;
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

	struct m0_fom *fom;
	struct m0_fom_rpclite_sender *fom_obj;
	struct fom_state fom_st;
	struct m0_reqh *reqh = c->connection.c_rpc_machine->rm_reqh;
	CHECK_RESULT(rc, create_sender_fom(&fom_obj,reqh,RPC_SENDER_TYPE_SEND,&fom_st), return rc);

	fom_obj->send.rpc_item = &msg->fop.f_item;

    if (m0_fop_payload_size(&msg->fop.f_item)+ITEM_SIZE_CUSHION > m0_rpc_session_get_max_item_size(&c->session)) {
        fprintf(stderr,"rpc_send: rpclite got a message which is too big"
                       ": %d vs %d\n", m0_fop_payload_size(&msg->fop.f_item)
                                     , m0_rpc_session_get_max_item_size(&c->session)-ITEM_SIZE_CUSHION
               );
exit(1);
    }
	run_sender_fom(fom_obj,reqh);
	return fom_st.rc;
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
