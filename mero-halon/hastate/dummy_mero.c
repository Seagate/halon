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
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "conf/confc.h"
#include "ha/note.h"
#include "reqh/reqh.h"
#include "rpclite.h"

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

static int walk_configuration(struct m0_conf_obj* obj, unsigned char** state);

static int walk_configuration_child(struct m0_conf_obj* obj,const struct m0_fid child,unsigned char** state){
    struct m0_conf_obj* dir;
    int rc = m0_confc_open_sync(&dir, obj, child);
    if (rc) {
        fprintf(stderr,"m0_confc_open_sync: %d %s\n",rc,strerror(-rc));
        exit(1);
    }
    rc = walk_configuration(dir,state);
    m0_confc_close(dir);
    return rc;
}

static int walk_configuration(struct m0_conf_obj* obj,unsigned char** state) {

    *(*state)++ = obj->co_ha_state;
    const struct m0_conf_obj_type *t = m0_conf_obj_type(obj);
    if (t == &M0_CONF_DIR_TYPE) {
        struct m0_conf_obj* item;
        int rc;
        for (item = NULL; (rc = m0_confc_readdir_sync(obj, &item)) > 0; ) {
            if (walk_configuration(item,state)) {
                m0_confc_close(item);
                return 1;
            }
        }
        m0_confc_close(item);
    } else if (t == &M0_CONF_PROFILE_TYPE) {
        return walk_configuration_child(obj,M0_CONF_PROFILE_FILESYSTEM_FID,state);
    } else if (t == &M0_CONF_FILESYSTEM_TYPE) {
        return walk_configuration_child(obj,M0_CONF_FILESYSTEM_SERVICES_FID,state);
    } else if (t == &M0_CONF_SERVICE_TYPE) {
        return walk_configuration_child(obj,M0_CONF_SERVICE_NODE_FID,state);
    } else if (t == &M0_CONF_NODE_TYPE) {
        if (walk_configuration_child(obj,M0_CONF_NODE_NICS_FID,state)) return 1;
        if (walk_configuration_child(obj,M0_CONF_NODE_SDEVS_FID,state)) return 1;
    } else if (t == &M0_CONF_NIC_TYPE || t == &M0_CONF_SDEV_TYPE) {
        return 0;
    } else {
        fprintf(stderr,"unknown configuration object type: %p\n",t);
        return 1;
    }
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

    dbdir = getenv("NTR_DB_DIR");
    if (dbdir == NULL)
         rc = rpc_init("");
    else {
         size_t destlen = strlen(dbdir) * sizeof(char) + 2;
         char *dest = malloc(destlen);
         strncpy(dest, dbdir, destlen);
         strncat(dest, "/", destlen);
         rc = rpc_init(dest);
    }
    if (rc) {
        fprintf(stderr,"rpc_init: %d",rc);
        return 1;
    }

    m0_ha_state_fop_init();
    m0_ha_state_init();

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
    // profile id taken from $MERO_ROOT/m0t1fs/linux_kernel/st/st
    rc = m0_confc_init(&reqh->rh_confc, &g_grp,
                       &M0_FID_TINIT('p',0x11,0)
                      ,argv[2],rpc_get_rpc_machine_re(ep), NULL);
    if (rc) {
        fprintf(stderr,"m0_confc_init: %d %s\n",rc,strerror(-rc));
        return 1;
    }

    unsigned char states[20];
    unsigned char* it = states;

    // Have objects loaded in the confc cache.
    rc = walk_configuration(reqh->rh_confc.cc_root,&it);

    printf("ready\n");

    // Wait for HA side to report itself.
    sem_wait(&reply_received);

    rpc_connection_t* c;

    // Connect to HA side.
    rc = rpc_connect_re(ep,argv[3],5,&c);
    if (rc) {
        fprintf(stderr,"rpc_connect_re: %d %s\n",rc,strerror(-rc));
        return 1;
    }

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

    // These literals are copied from
    // $MERO_ROOT/m0t1fs/linux_kernel/st/st
    struct m0_ha_note n2[] = {
         { M0_FID_TINIT('n', 1, 1), M0_NC_OFFLINE    },
         { M0_FID_TINIT('n', 1, 0),  M0_NC_RECOVERING }
    };
    struct m0_ha_nvec note_to_set = { 2, n2 };
    m0_ha_state_set(rpc_get_session(c), &note_to_set);

    struct iovec segments[] = { { .iov_base = (void*)&n.no_state, .iov_len = sizeof(n.no_state) }
                              };

    rpc_send_blocking(c,segments,1,5);

    // We wait a message from the HA side to learn when confc has been modified.
    sem_wait(&reply_received);

    it = states;
    rc = walk_configuration(reqh->rh_confc.cc_root,&it);

    struct iovec segments2[] = { { .iov_base = (void*)states, .iov_len = sizeof(states) }
                               };

    rpc_send_blocking(c,segments2,1,5);

    // Wait indefinitely. The process should be killed.
    //
    // XXX: We don't execute the subsequent disconnection and finalization
    // calls to avoid a race condition in rpc_stop_listening which results in
    // crash during tests.
    sem_wait(&reply_received);

    rpc_disconnect(c,5);

    m0_confc_fini(&reqh->rh_confc);

    ast_thread_fini();

    rpc_stop_listening(ep);

    m0_ha_state_fini();
    rpc_fini();
    return rc;
}
