//
// Copyright : (C) 2013-2018 Seagate Technology LLC and/or its Affiliates.
// License   : Apache License, Version 2.0.
//

#define M0_TRACE_SUBSYSTEM M0_TRACE_SUBSYS_HA
#include "lib/trace.h"

#include "confc_helpers.h"

#include "ha/halon/interface.h"  // m0_halon_interface_spiel
#include "conf/validation.h"
#include "m0init.h"              // m0init_hi
#include "spiel/spiel.h"         // m0_spiel_tx
#include <stdlib.h>              // malloc

char *confc_validate_cache_of_tx(struct m0_spiel_tx *tx, size_t buflen)
{
	char *buf;
	char *err;

	buf = malloc(buflen);
	if (buf == NULL)
		return NULL;

	err = m0_conf_validation_error(&tx->spt_cache, buf, buflen);
	if (err == NULL) {
		free(buf);
		return NULL;
	}
	return buf;
}

struct m0_spiel *halon_interface_spiel(void)
{
	return m0_halon_interface_spiel(m0init_hi);
}

#undef M0_TRACE_SUBSYSTEM
