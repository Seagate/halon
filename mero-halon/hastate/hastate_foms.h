//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

#pragma once

#include "config.h"
#include "fop/fom.h"
#include "ha/note.h"

extern const struct m0_fom_ops ha_state_get_fom_ops;
extern const struct m0_fom_type_ops ha_state_get_fom_type_ops;

extern const struct m0_fom_ops ha_state_set_fom_ops;
extern const struct m0_fom_type_ops ha_state_set_fom_type_ops;

// in ha/note.h
extern const struct m0_fom_ops ha_entrypoint_get_ops;
extern const struct m0_fom_type_ops ha_entrypoint_fom_type_ops;

/**
 * Foms for ha_state_get requests.
 * 
 * The note context is needed so we can find the corresponding fom
 * from a state vector which comes back from upper layers.
 */
struct ha_state_get_fom {
     struct m0_fom  fp_gen;
     struct m0_ha_nvec fp_note;
     int fp_rc;
};
