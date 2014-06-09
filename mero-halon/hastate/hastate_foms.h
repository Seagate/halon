//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#pragma once

#include "fop/fom.h"

extern const struct m0_fom_ops ha_state_get_fom_ops;
extern const struct m0_fom_type_ops ha_state_get_fom_type_ops;

extern const struct m0_fom_ops ha_state_set_fom_ops;
extern const struct m0_fom_type_ops ha_state_set_fom_type_ops;

/* Wrapper structure to enclose m0_ha_nvec and fop. */
struct note_context {
     struct m0_ha_nvec  nc_note;
     struct m0_fom      *nc_fom;
     int                nc_rc;
};
