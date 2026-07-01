/*-------------------------------------------------------------------------
 *
 * toasting.h
 *	  This file provides some definitions to support creation of toast tables
 *
 *
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/catalog/toasting.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef TOASTING_H
#define TOASTING_H

#include "storage/lock.h"

/*
 * toasting.c prototypes
 */
extern void NewRelationCreateToastTable(Oid relOid, Datum reloptions);
extern void NewHeapCreateToastTable(Oid relOid, Datum reloptions,
									LOCKMODE lockmode);
extern void AlterTableCreateToastTable(Oid relOid, Datum reloptions,
									   LOCKMODE lockmode);
extern void BootstrapToastTable(char *relName,
								Oid toastOid, Oid toastIndexOid);

/*
 * GPDB_14_MERGE_FIXME: Upstream PostgreSQL moved every DECLARE_TOAST
 * declaration (and the matching *ToastTable/*ToastIndex defines) out of
 * toasting.h into the individual catalog headers, and dropped toasting.h from
 * the genbki.pl source list (POSTGRES_BKI_SRCS in src/backend/catalog/Makefile).
 * The standard-catalog toast declarations now live in their respective pg_*.h
 * headers, so they are intentionally not duplicated here anymore.
 *
 * The GPDB-specific toast declarations below still need to be relocated into
 * their own catalog headers (gp_partition_template.h, pg_attribute_encoding.h,
 * pg_type_encoding.h, pg_extprotocol.h and gp_segment_configuration.h) so that
 * genbki.pl actually emits these toast tables.  They are kept here for now to
 * preserve the hard-wired OIDs and the GpSegmentConfigToast* defines (referenced
 * by catalog.c); move them when those GG catalog headers are touched.
 */

/*
 * This macro is just to keep the C compiler from spitting up on the
 * upcoming commands for Catalog.pm.
 */
#define DECLARE_TOAST(name,toastoid,indexoid) extern int no_such_variable

/* GPDB additional normal catalogs */
DECLARE_TOAST(gp_partition_template, 8024, 8025);
DECLARE_TOAST(pg_attribute_encoding, 6233, 6234);
DECLARE_TOAST(pg_type_encoding, 6222, 6223);
DECLARE_TOAST(pg_extprotocol, 7173, 7174);

/* GPDB additional shared catalogs */
DECLARE_TOAST(gp_segment_configuration, 6092, 6093);
#define GpSegmentConfigToastTable	6092
#define GpSegmentConfigToastIndex	6093

#endif							/* TOASTING_H */
