/**
 * Copyright : (C) 2013 Xyratex Technology Limited.
 * License   : All rights reserved.
 *
 * This program tests the healthiness of confd.
 *
 * It connects to confd and traverses the configuration tree.
 *
 * On success returns exit code 0, otherwise it return a non-zero value.
 *
 * */
#include "rpclite.h"
#include "m0init.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "conf/confc.h"
#include "ha/note.h"
#include "reqh/reqh.h"

static struct m0_sm_group g_grp;

static struct {
    bool             run;
    struct m0_thread thread;
} g_ast;

static void ast_thread(int _ __attribute__((unused)))
{
    while (g_ast.run) {
        m0_chan_wait(&g_grp.s_clink);
        m0_sm_group_lock(&g_grp);
        m0_sm_asts_run(&g_grp);
        m0_sm_group_unlock(&g_grp);
    }
}

static void ast_thread_init(void)
{
    m0_sm_group_init(&g_grp);
    g_ast.run = true;
    M0_ASSERT(M0_THREAD_INIT(&g_ast.thread, int, NULL, &ast_thread, 0,
                             "ast_thread") == 0);
}

static void ast_thread_fini(void)
{
    g_ast.run = false;
    m0_clink_signal(&g_grp.s_clink);
    m0_thread_join(&g_ast.thread);
    m0_sm_group_fini(&g_grp);
}

sem_t reply_received;

int rcv(rpc_item_t* it,void* ctx) {
    sem_post(&reply_received);

    return 0;
}

int main(int argc,char** argv) {
    int rc;
    char *dbdir;

    if (argc!=4) {
        fprintf(stderr,"USAGE: %s <local RPC address> <confd RPC address> <HA RPC address>\n"
                "\n"
                "Returns 0 on success, nonzero if confd could not be contacted."
               , argv[0]);
        return 0;
    }

    m0_init_wrapper();
    rc = rpc_init();
    if (rc) {
        fprintf(stderr,"rpc_init: %d",rc);
        return 1;
    }

    m0_ha_state_fop_init();

    sem_init(&reply_received,0,0);

    rpc_receive_endpoint_t* ep;
    rc = rpc_listen(dbdir == NULL ? "s1" : strcat(dbdir, "/s1"), argv[1],
                    &(rpc_listen_callbacks_t){ .receive_callback=rcv },&ep);
    if (rc) {
        fprintf(stderr,"rpc_listen: %d",rc);
        return 1;
    }

    ast_thread_init();
    struct m0_reqh* reqh = rpc_get_rpc_machine_re(ep)->rm_reqh;
    rc = m0_confc_init(&reqh->rh_confc, &g_grp
                      ,argv[2],rpc_get_rpc_machine_re(ep), NULL);
    if (rc) {
        fprintf(stderr,"m0_confc_init: %d %s\n",rc,strerror(-rc));
        return 1;
    }

    printf("ready\n");

    // Wait for HA side to report itself.
	while ((rc = sem_wait(&reply_received)) && errno == EINTR)
      continue;

    rpc_connection_t* c;

    // Connect to HA side.
    rc = rpc_connect_re(ep,argv[3],5,&c);
    if (rc) {
        fprintf(stderr,"rpc_connect_re: %d %s\n",rc,strerror(-rc));
        return 1;
    }

    m0_ha_state_init(rpc_get_session(c));
    printf("connected to HA side\n");

    struct m0_ha_note n = { M0_FID_TINIT('n', 1, 1), M0_NC_UNKNOWN };
    struct m0_ha_nvec note = { 1, &n };

    struct m0_mutex chan_lock;
    struct m0_chan chan;
    struct m0_clink clink;

    m0_mutex_init(&chan_lock);
    m0_chan_init(&chan,&chan_lock);
    m0_clink_init(&clink,NULL);
    m0_clink_add_lock(&chan,&clink);

    rc = m0_ha_state_get(rpc_get_session(c), &note, &chan);
    if (rc) {
        fprintf(stderr,"m0_ha_state_get: %d %s\n",rc,strerror(-rc));
        return 1;
    }

    m0_chan_wait(&clink);
    m0_clink_del_lock(&clink);
    m0_clink_fini(&clink);
    m0_chan_fini_lock(&chan);
    m0_mutex_fini(&chan_lock);

    printf("m0_ha_state_get completed\n");
    struct iovec segments[] = { { .iov_base = (void*)&n.no_state, .iov_len = sizeof(n.no_state) }
                              };

    rpc_send_blocking(c,segments,1,5);
    printf("m0_ha_state_get result sent\n");

    // These literals are imitated from
    // _sandbox.conf-st/cont.txt which is generated by
    // $MERO_ROOT/conf/st sstart
    // It really doesn't matter which literals are used here
    // as long as they match the expectation of the test driver
    // on the HA side.
    struct m0_ha_note n2[] = {
         { M0_FID_TINIT('n', 1, 1), M0_NC_ONLINE    },
         { M0_FID_TINIT('n', 1, 0),  M0_NC_TRANSIENT }
    };
    struct m0_ha_nvec note_to_set = { 2, n2 };
    m0_ha_state_set(rpc_get_session(c), &note_to_set);
    printf("m0_ha_state_set completed\n");

    // We wait a message from the HA side to learn when confc has been modified.
	while ((rc = sem_wait(&reply_received)) && errno == EINTR)
      continue;
    printf("confc was modified\n");

    unsigned char state = reqh->rh_confc.cc_root->co_ha_state;
    struct iovec segments2[] = { { .iov_base = (void*)&state, .iov_len = sizeof(state) }
                               };

    rpc_send_blocking(c,segments2,1,5);
    printf("m0_ha_state_accept result was sent\n");

    // Wait indefinitely. The process should be killed.
    //
    // XXX: We don't execute the subsequent finalization
    // calls to avoid a race condition in rpc_stop_listening which results in
    // crash during tests.
	while ((rc = sem_wait(&reply_received)) && errno == EINTR)
      continue;

    m0_ha_state_fini();

    rpc_disconnect(c,5);

    m0_confc_fini(&reqh->rh_confc);

    ast_thread_fini();

    rpc_stop_listening(ep);

    rpc_fini();
    m0_fini();
    return rc;
}
