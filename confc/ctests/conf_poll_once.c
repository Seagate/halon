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
#include "rpclite.h"

static struct m0_confc confc;
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

static const char* show_service_type(enum m0_conf_service_type t) {
	switch(t) {
		case  M0_CST_MDS:
			return "M0_CST_MDS";
		case M0_CST_IOS:
			return "M0_CST_IOS";
		case M0_CST_CONFD:
			return "M0_CST_CONFD";
		case M0_CST_DLM:
			return "M0_CST_DLM";
		default:
			return "unknown";
	}
}

static int walk_configuration(struct m0_conf_obj* obj);

static int walk_configuration_child(struct m0_conf_obj* obj,char* child){
	struct m0_conf_obj* dir;
	int rc = m0_confc_open_sync(&dir, obj, M0_BUF_INITS(child));
    if (rc) {
		fprintf(stderr,"m0_confc_open_sync: %d %s\n",rc,strerror(-rc));
		exit(1);
	}
	rc = walk_configuration(dir);
	m0_confc_close(dir);
	return rc;
}

static int walk_configuration(struct m0_conf_obj* obj) {
	
	switch(obj->co_type) {
		case M0_CO_DIR: 
		{
			struct m0_conf_obj* item;
			int rc;
			for (item = NULL; (rc = m0_confc_readdir_sync(obj, &item)) > 0; ) {
				if (walk_configuration(item)) {
					m0_confc_close(item);
					return 1;
				}
			}
			m0_confc_close(item);
		}
			break;
		case M0_CO_PROFILE:
			break;
		case M0_CO_FILESYSTEM: 
		{
			struct m0_conf_filesystem* fs = M0_CONF_CAST(obj,m0_conf_filesystem);
			return walk_configuration_child(obj,"services");
		}
		break;
	
		case M0_CO_SERVICE:
		{
			struct m0_conf_service* svc = M0_CONF_CAST(obj,m0_conf_service);
			return walk_configuration_child(obj,"node");
		}
		break;

		case M0_CO_NODE:
		{
			struct m0_conf_node* node = M0_CONF_CAST(obj,m0_conf_node);
			if (walk_configuration_child(obj,"nics")) return 1;
			if (walk_configuration_child(obj,"sdevs")) return 1;
		}
		break;

		case M0_CO_NIC:
		{
			struct m0_conf_nic* nic = M0_CONF_CAST(obj,m0_conf_nic);
		}
		break;

		case M0_CO_SDEV:
		{
			struct m0_conf_sdev* sdev = M0_CONF_CAST(obj,m0_conf_sdev);
			return walk_configuration_child(obj,"partitions");
		}
		break;

		case M0_CO_PARTITION:
		{
			struct m0_conf_partition* part = M0_CONF_CAST(obj,m0_conf_partition);
		}
		break;

		case M0_CO_NR:
		default:
			fprintf(stderr,"unknown configuration object type: %d\n",obj->co_type);
			return 1;
	}
	return 0;
}

int main(int argc,char** argv) {
	int rc;

	if (argc<3) {
		fprintf(stderr,"USAGE: confc_test <confc RPC address> <confd RPC address>\n"
				"\n"
				"Returns 0 on success, nonzero if confd could not be contacted.");
		return 0;
	}

	rc = rpc_init("");
	if (rc) {
		fprintf(stderr,"rpc_init: %d",rc);
		return 1;
	}

	rpc_endpoint_t* ep;
	rc = rpc_create_endpoint(argv[1],&ep);
	if (rc) {
		fprintf(stderr,"rpc_create_endpoint: %d",rc);
		return 1;
	}

	ast_thread_init();

	rc = m0_confc_init(&confc, &g_grp,
                           &M0_BUF_INITS((char *)"prof-10000000000")
	                  ,argv[2],rpc_get_rpc_machine(ep), NULL);
    if (rc) {
		fprintf(stderr,"m0_confc_init: %d %s\n",rc,strerror(-rc));
		return 1;
	}
	
	struct m0_conf_obj* fs;
	rc = m0_confc_open_sync(&fs, confc.cc_root, M0_BUF_INITS("filesystem"));
    if (rc) {
		fprintf(stderr,"m0_confc_open_sync: %d %s\n",rc,strerror(-rc));
		return 1;
	}

	rc = walk_configuration(fs);

	m0_confc_close(fs);

	m0_confc_fini(&confc);

	ast_thread_fini();

	rpc_destroy_endpoint(ep);
	rpc_fini();
	return rc;
}
