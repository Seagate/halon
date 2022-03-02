//
// Copyright (C) 2013-2018 Seagate Technology LLC and/or its Affiliates. Apache License, Version 2.0.
//
// See the accompanying COPYING file for license information.
//
#pragma once
#ifndef __H0_CONFC_HELPERS_H__
#define __H0_CONFC_HELPERS_H__

struct m0_halon_interface;
struct m0_spiel;
struct m0_spiel_tx;

/**
 * Skip the hoops we'd have to jump in capi and just use a helper to
 * validate cache stashed in m0_spiel_tx.
 *
 * Caller should free the resulting string.
 */
char *confc_validate_cache_of_tx(struct m0_spiel_tx *tx, size_t buflen);

/** Get current spiel context from m0_halon_interface. */
struct m0_spiel *halon_interface_spiel(void);

#endif  // __H0_CONFC_HELPERS_H__
