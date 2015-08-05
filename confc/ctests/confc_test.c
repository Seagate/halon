//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

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
		case M0_CST_MGS:
			return "M0_CST_MGS";
		case M0_CST_RMS:
			return "M0_CST_RMS";
		case M0_CST_STS:
			return "M0_CST_STS";
		case M0_CST_HA:
			return "M0_CST_HA";
		case M0_CST_SSS:
			return "M0_CST_SSS";
		default:
			return "unknown";
	}
}

static void print_configuration(int indentation,struct m0_conf_obj* obj);

static void print_configuration_child(int newi,const char* label,struct m0_conf_obj* obj,struct m0_fid child){
	struct m0_conf_obj* dir;
	int rc = m0_confc_open_sync(&dir, obj, child);
    if (rc) {
		fprintf(stderr,"m0_confc_open_sync: %d %s\n",rc,strerror(-rc));
		exit(1);
	}
	printf("%*.*c",newi,newi,' ');
	printf("%s: ",label);
	print_configuration(newi,dir);
	m0_confc_close(dir);
}

static void print_configuration(int indentation,struct m0_conf_obj* obj) {

	int newi = indentation+2;
	printf("m0_fid(0x%lX,%lu): ",obj->co_id.f_container,obj->co_id.f_key);
	const struct m0_conf_obj_type *t = m0_conf_obj_type(obj);
	if (t == &M0_CONF_DIR_TYPE) {
		printf("m0_conf_dir {}\n");
		struct m0_conf_obj* item;
		int rc;
		for (item = NULL; (rc = m0_confc_readdir_sync(obj, &item)) > 0; ) {
			printf("%*.*c",newi,newi,' ');
			print_configuration(newi,item);
		}
		m0_confc_close(item);
	}
	else if (t == &M0_CONF_PROFILE_TYPE) {
		printf("m0_conf_profile {}\n");
		print_configuration_child(newi,"filesystem",obj,M0_CONF_PROFILE_FILESYSTEM_FID);
	}
	else if (t == &M0_CONF_FILESYSTEM_TYPE) {
		struct m0_conf_filesystem* fs = M0_CONF_CAST(obj,m0_conf_filesystem);
		printf("m0_conf_filesystem { ");
		printf("rootfid = m0_fid(0x%lX,%lu), "
				,fs->cf_rootfid.f_container,fs->cf_rootfid.f_key);
		if (*fs->cf_params) {
			printf("params = [ ");
			printf("%s",*fs->cf_params);
			const char** s;
			for(s=fs->cf_params+1;*s;s+=1)
				printf(" %s",*s);
			printf(" ] }\n");
		} else
			printf(" params = [] }\n");
		print_configuration_child(newi,"services",obj,M0_CONF_FILESYSTEM_SERVICES_FID);
	}
	else if (t == &M0_CONF_SERVICE_TYPE) {
		struct m0_conf_service* svc = M0_CONF_CAST(obj,m0_conf_service);
		printf("m0_conf_service { type = %s, ",show_service_type(svc->cs_type));
		if (*svc->cs_endpoints) {
			printf("endpoints = [ ");
			printf("%s",*svc->cs_endpoints);
			const char** s;
			for(s=svc->cs_endpoints+1;*s;s+=1)
				printf(", %s",*s);
			printf(" ] }\n");
		} else
			printf(" endpoints = [] }\n");
		print_configuration_child(newi,"node",obj,M0_CONF_SERVICE_NODE_FID);
	}
	else if (t == &M0_CONF_NODE_TYPE) {
		struct m0_conf_node* node = M0_CONF_CAST(obj,m0_conf_node);
		printf("m0_conf_node { memsize = %u, nr_cpu = %u, "
				,node->cn_memsize,node->cn_nr_cpu);
		printf("last_state = %lu, flags = %lu, pool_id = %lu }\n"
				,node->cn_last_state
				,node->cn_flags
				);
		print_configuration_child(newi,"nics",obj,M0_CONF_NODE_NICS_FID);
		print_configuration_child(newi,"sdevs",obj,M0_CONF_NODE_SDEVS_FID);
	}
	else if (t == &M0_CONF_NIC_TYPE) {
		struct m0_conf_nic* nic = M0_CONF_CAST(obj,m0_conf_nic);
		printf("m0_conf_nic { iface = %u, mtu = %u, "
				,nic->ni_iface,nic->ni_mtu);
		printf("speed = %lu, filename = %s, last_state = %lu }\n"
				,nic->ni_speed,nic->ni_filename,nic->ni_last_state);
	}
	else if (t == &M0_CONF_SDEV_TYPE) {
		struct m0_conf_sdev* sdev = M0_CONF_CAST(obj,m0_conf_sdev);
		printf("m0_conf_sdev { iface = %u, media = %u, "
				,sdev->sd_iface,sdev->sd_media);
		printf("size = %lu, last_state = %lu, flags = %lu, "
				,sdev->sd_size,sdev->sd_last_state,sdev->sd_flags);
		printf("filename = %s }\n",sdev->sd_filename);
	}
	else {
		fprintf(stderr,"unknown configuration object type: m0_fid_type(%d,%s)\n"
				,t->cot_ftype.ft_id,t->cot_ftype.ft_name);
	}
}

int main(int argc,char** argv) {
	int rc;
	char *dbdir;

	if (argc<2) {
		fprintf(stderr,"USAGE: confc_test <nid>\n");
		return 0;
	}

	dbdir = getenv("NTR_DB_DIR");
        if (dbdir == NULL)
             rc = rpc_init("");
        else {
             size_t destlen = (strlen(dbdir) * sizeof(char)) + 2;
             char *dest = malloc(destlen);
             strncpy(dest, dbdir, destlen);
             strncat(dest, "/", destlen);
             rc = rpc_init(dest);
        }

	if (rc) {
		fprintf(stderr,"rpc_init: %d",rc);
		return 1;
	}

	rpc_endpoint_t* ep;
	char ep_addr[100];
	strcpy(ep_addr,argv[1]);
	strcat(ep_addr,":12345:34:401");
	rc = rpc_create_endpoint(ep_addr,&ep);
	if (rc) {
		fprintf(stderr,"rpc_create_endpoint: %d",rc);
		return 1;
	}

	ast_thread_init();

	char confd_addr[100];
	strcpy(confd_addr,argv[1]);
	strcat(confd_addr,":12345:34:1001");
	const struct m0_fid prof_fid = M0_FID_TINIT('p',17,0);
	rc = m0_confc_init(&confc, &g_grp, &prof_fid,
	                  confd_addr,rpc_get_rpc_machine(ep), NULL);
    if (rc) {
		fprintf(stderr,"m0_confc_init: %d %s\n",rc,strerror(-rc));
		return 1;
	}

	print_configuration(0,confc.cc_root);

	m0_confc_fini(&confc);

	ast_thread_fini();

	rpc_destroy_endpoint(ep);
	rpc_fini();
	return 0;
}
