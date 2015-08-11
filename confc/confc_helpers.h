//
// Copyright (C) 2013 Xyratex Technology Limited. All rights reserved.
//
// See the accompanying COPYING file for license information.
//

#pragma once

#include "conf/confc.h"
#include "conf/obj.h"


/// Call rpc_init() before calling confc_init.
int confc_init();

int confc_create(struct m0_confc** c,const struct m0_fid* prof
                ,const char* confd_addrs,struct m0_rpc_machine* m);

void confc_destroy(struct m0_confc* c);

/// Call rpc_fini() after calling confc_fini.
void confc_finalize();

//
// Fetching operations
//

int confc_open_sync(struct m0_conf_obj** result,struct m0_conf_obj* parent,const struct m0_fid *child);

// int m0_confc_readdir_sync(struct m0_conf_obj* obj,struct m0_conf_obj** item);
// void m0_confc_close(struct m0_confc_obj*);

//
// Casting helpers
//
struct m0_conf_dir* confc_cast_dir(struct m0_conf_obj* obj);

struct m0_conf_root* confc_cast_root(struct m0_conf_obj* obj);

struct m0_conf_profile* confc_cast_profile(struct m0_conf_obj* obj);

struct m0_conf_filesystem* confc_cast_filesystem(struct m0_conf_obj* obj);

struct m0_conf_pool* confc_cast_pool(struct m0_conf_obj* obj);

struct m0_conf_pver* confc_cast_pver(struct m0_conf_obj* obj);

struct m0_conf_objv* confc_cast_objv(struct m0_conf_obj* obj);

struct m0_conf_node* confc_cast_node(struct m0_conf_obj* obj);

struct m0_conf_process* confc_cast_process(struct m0_conf_obj* obj);

struct m0_conf_service* confc_cast_service(struct m0_conf_obj* obj);

struct m0_conf_sdev* confc_cast_sdev(struct m0_conf_obj* obj);

struct m0_conf_rack* confc_cast_rack(struct m0_conf_obj* obj);

struct m0_conf_enclosure* confc_cast_enclosure(struct m0_conf_obj* obj);

struct m0_conf_controller* confc_cast_controller(struct m0_conf_obj* obj);

struct m0_conf_disk* confc_cast_disk(struct m0_conf_obj* obj);

// Workaround for MERO-1088
struct m0_fid *cn_pool_fid(struct m0_conf_node *node);
// Workarounds for MERO-1089
struct m0_fid *cc_node_fid(struct m0_conf_controller *cont);
struct m0_fid *cv_real_fid(struct m0_conf_objv *obj);
// Workaround for MERO-1094
struct m0_fid *ck_sdev_fid(struct m0_conf_disk *disk);
