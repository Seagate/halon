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

struct m0_conf_filesystem* confc_cast_filesystem(struct m0_conf_obj* obj);

struct m0_conf_service* confc_cast_service(struct m0_conf_obj* obj);

struct m0_conf_node* confc_cast_node(struct m0_conf_obj* obj);

struct m0_conf_nic* confc_cast_nic(struct m0_conf_obj* obj);

struct m0_conf_sdev* confc_cast_sdev(struct m0_conf_obj* obj);

// Can't extract pointer in Haskell...
const struct m0_conf_obj_type* CONF_PROFILE_TYPE = & M0_CONF_PROFILE_TYPE;
const struct m0_conf_obj_type* CONF_FILESYSTEM_TYPE = & M0_CONF_FILESYSTEM_TYPE;
const struct m0_conf_obj_type* CONF_SERVICE_TYPE = & M0_CONF_SERVICE_TYPE;
const struct m0_conf_obj_type* CONF_NODE_TYPE = & M0_CONF_NODE_TYPE;
const struct m0_conf_obj_type* CONF_NIC_TYPE = & M0_CONF_NIC_TYPE;
const struct m0_conf_obj_type* CONF_SDEV_TYPE = & M0_CONF_SDEV_TYPE;
const struct m0_conf_obj_type* CONF_DIR_TYPE = & M0_CONF_DIR_TYPE;

const struct m0_fid *CONF_FILESYSTEM_SERVICES_FID = & M0_CONF_FILESYSTEM_SERVICES_FID;
const struct m0_fid *CONF_PROFILE_FILESYSTEM_FID = & M0_CONF_PROFILE_FILESYSTEM_FID;
const struct m0_fid *CONF_SERVICE_NODE_FID = & M0_CONF_SERVICE_NODE_FID;
const struct m0_fid *CONF_NODE_NICS_FID = & M0_CONF_NODE_NICS_FID;
const struct m0_fid *CONF_NODE_SDEVS_FID = & M0_CONF_NODE_SDEVS_FID;
