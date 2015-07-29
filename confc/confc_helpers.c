//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "conf/confc.h"

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


int confc_init() {
	ast_thread_init();
	return 0;
}

int confc_create(struct m0_confc** c,const struct m0_fid* prof
                ,const char* confd_addrs,struct m0_rpc_machine* m) {
	int rc=0;
    *c = (struct m0_confc*)malloc(sizeof(struct m0_confc));
    if (*c==NULL)
        return ENOMEM;

	rc = m0_confc_init(*c, &g_grp,
	                   confd_addrs,m, NULL);
	if (rc)
		fprintf(stderr,"m0_confc_init: %d %s\n",rc,strerror(-rc));
    return rc;
}

void confc_destroy(struct m0_confc* c) {
	m0_confc_fini(c);
	free(c);
}

void confc_finalize() {
	ast_thread_fini();
}

const struct m0_fid *CONF_ROOT_FID = &M0_CONF_ROOT_FID;

struct m0_conf_dir* confc_cast_dir(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_dir);
}

struct m0_conf_root* confc_cast_root(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_root);
};

struct m0_conf_profile* confc_cast_profile(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_profile);
};

struct m0_conf_filesystem* confc_cast_filesystem(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_filesystem);
};

struct m0_conf_pool* confc_cast_pool(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_pool);
};

struct m0_conf_pver* confc_cast_pver(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_pver);
};

struct m0_conf_objv* confc_cast_objv(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_objv);
};

struct m0_conf_node* confc_cast_node(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_node);
};

struct m0_conf_process* confc_cast_process(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_process);
};

struct m0_conf_service* confc_cast_service(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_service);
};

struct m0_conf_sdev* confc_cast_sdev(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_sdev);
};

struct m0_conf_rack* confc_cast_rack(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_rack);
};

struct m0_conf_enclosure* confc_cast_enclosure(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_enclosure);
};

struct m0_conf_controller* confc_cast_controller(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_controller);
};

struct m0_conf_disk* confc_cast_disk(struct m0_conf_obj* obj) {
    return M0_CONF_CAST(obj, m0_conf_disk);
};


int confc_open_sync(struct m0_conf_obj** result,struct m0_conf_obj* parent,const struct m0_fid *child) {
    return m0_confc_open_sync(result,parent,*child);
}

// void m0_confc_close(struct m0_confc_obj*);

// int m0_confc_readdir_sync(struct m0_conf_obj* obj,struct m0_conf_obj** item);

