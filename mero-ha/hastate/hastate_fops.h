//
// Copyright : (C) 2013 Xyratex Technology Limited.
// License   : All rights reserved.
//

void ha_state_fop_fini(void);

int ha_state_fop_init(void);

extern struct m0_fop_type ha_state_get_fopt;
extern struct m0_fop_type ha_state_get_rep_fopt;
extern struct m0_fop_type ha_state_set_fopt;
