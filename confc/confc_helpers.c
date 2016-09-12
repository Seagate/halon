//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#define M0_TRACE_SUBSYSTEM M0_TRACE_SUBSYS_HA
#include "lib/trace.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "conf/confc.h"
#include "conf/validation.h"
#include "fid/fid.h"
#include "reqh/reqh_service.h"
#include "rm/rm_service.h"
#include "spiel/spiel.h"
#include "m0init.h"       /* m0init_hi */
#include "ha/halon/interface.h"

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

// Temporary workaround
struct m0_fid *cn_pool_fid(struct m0_conf_node *node) {
    return &(node->cn_pool->pl_obj.co_id);
}
struct m0_fid *cc_node_fid(struct m0_conf_controller *cont) {
    return &(cont->cc_node->cn_obj.co_id);
}
struct m0_fid *cv_real_fid(struct m0_conf_objv *obj) {
    return &(obj->cv_real->co_id);
}
// Workaround for MERO-1094
struct m0_fid *ck_sdev_fid(struct m0_conf_disk *disk) {
    return &(disk->ck_dev->sd_obj.co_id);
}

// Skip the hoops we'd have to jump in capi and just use a helper to
// validate cache stashed in m0_spiel_tx .
// Caller should free the resulting string
char *confc_validate_cache_of_tx(struct m0_spiel_tx *tx, size_t buflen) {
  char *buf = (char *) malloc(buflen);
  struct m0_conf_cache *conf_cache = (struct m0_conf_cache *) &(tx->spt_cache);
  char *result = m0_conf_validation_error(conf_cache, buf, buflen);

  if (result == NULL) {
    free(buf);
    return NULL;
  } else {
    return buf;
  }
}

// Get current spiel.
struct m0_spiel * halon_interface_spiel() {
  return m0_halon_interface_spiel(m0init_hi);
}
