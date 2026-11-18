/* -------------------------------------------------------------------------
 *
 * pgstat_gp.c
 *	  Implementation of resource queue statistics.
 *
 * This file contains the Greengage extensions to the cumulative statistics
 * system that used to live in the removed UDP-collector pgstat.c: the
 * backend-local per-portal accounting of resource queue execute and wait
 * times, and its aggregation into cross-backend per-queue totals.
 *
 * Resource queue stats work a bit differently from the other
 * variable-numbered stats.  A backend does not accumulate them in a pending
 * entry; it keeps a hash of PgStat_StatPortalEntry keyed by portal id, which
 * the pgstat_count_queue_* and pgstat_record_*_queue_* macros in pgstat.h
 * update in place, and pgstat_report_queuestat() folds that hash into the
 * shared PGSTAT_KIND_RESQUEUE entry at the end of each statement.  The shared
 * entry is therefore updated synchronously, the way replication slot stats
 * are, and needs no flush callback.
 *
 * Entries are keyed by queue OID with InvalidOid as the database OID, because
 * resource queues are shared across databases.
 *
 * Copyright (c) 2001-2022, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/backend/utils/activity/pgstat_gp.c
 * -------------------------------------------------------------------------
 */

#include "postgres.h"

#include "utils/hsearch.h"
#include "utils/pgstat_internal.h"

/* GUC parameter */
bool		pgstat_collect_queuelevel = false;

/*
 * Backend-local cache of resource queue statistics, one entry per portal.
 */
static HTAB *localStatPortalHash = NULL;


/* ----------
 * pgstat_init_localportalhash() -
 *
 *  Cache for portal statistics for a backend.
 * ----------
 */
void
pgstat_init_localportalhash(void)
{
	HASHCTL		info;
	int			hash_flags;

	info.keysize = sizeof(uint32);
	info.entrysize = sizeof(PgStat_StatPortalEntry);
	info.hash = tag_hash;
	hash_flags = (HASH_ELEM | HASH_FUNCTION);

	localStatPortalHash = hash_create("Local Stat Portal Hash",
									 1,
									 &info,
									 hash_flags);

	return;
}


/* ----------
 * pgstat_getportalentry() -
 *
 *  Return the (PgStat_StatPortalEntry *) for a given portal (and backend).
 * ----------
 */
PgStat_StatPortalEntry *
pgstat_getportalentry(uint32 portalid, Oid queueid)
{
	PgStat_StatPortalEntry	*portalentry;

	bool					found;

	portalentry = hash_search(localStatPortalHash,
							  (void *) &portalid,
							  HASH_ENTER, &found);

	Assert(portalentry != NULL);

	/* Initialize if this we have not seen this portal before! */
	if (!found || portalentry->queueentry.queueid == InvalidOid)
	{
		portalentry->portalid = portalid;
		portalentry->queueentry.queueid = queueid;
		portalentry->queueentry.n_queries_exec = 0;
		portalentry->queueentry.n_queries_wait = 0;
		portalentry->queueentry.elapsed_exec = 0;
		portalentry->queueentry.elapsed_wait = 0;
	}

	return portalentry;
}


/* ----------
 * pgstat_report_queuestat() -
 *
 *	Called from tcop/postgres.c to fold the so far collected per resource
 *	queue statistics into the shared statistics.
 * ----------
 */
void
pgstat_report_queuestat(void)
{
	HASH_SEQ_STATUS			hstat;
	PgStat_StatPortalEntry	*pentry;

	/* Not collecting queue stats, or nothing was ever collected. */
	if (!pgstat_collect_queuelevel || localStatPortalHash == NULL)
		return;

	/* Do a sequential scan through the local portal/queue hash*/
	hash_seq_init(&hstat, localStatPortalHash);
	while ((pentry = (PgStat_StatPortalEntry *) hash_seq_search(&hstat)) != NULL)
	{
		PgStat_EntryRef *entry_ref;
		PgStat_StatQueueEntry *statent;

		/* Skip if there is nothing to report. */
		if (pentry->queueentry.n_queries_exec == 0 &&
			pentry->queueentry.n_queries_wait == 0 &&
			pentry->queueentry.elapsed_exec == 0 &&
			pentry->queueentry.elapsed_wait == 0)
			continue;

		/* Add this portal's counters to the shared per-queue entry. */
		entry_ref = pgstat_get_entry_ref_locked(PGSTAT_KIND_RESQUEUE,
												InvalidOid,
												pentry->queueentry.queueid,
												false);
		statent = &((PgStatShared_Resqueue *) entry_ref->shared_stats)->stats;

		statent->queueid = pentry->queueentry.queueid;
		statent->n_queries_exec += pentry->queueentry.n_queries_exec;
		statent->n_queries_wait += pentry->queueentry.n_queries_wait;
		statent->elapsed_exec += pentry->queueentry.elapsed_exec;
		statent->elapsed_wait += pentry->queueentry.elapsed_wait;

		pgstat_unlock_entry(entry_ref);

		/* Reset the counters for this entry. */
		pentry->queueentry.queueid = InvalidOid;
		pentry->queueentry.n_queries_exec = 0;
		pentry->queueentry.n_queries_wait = 0;
		pentry->queueentry.elapsed_exec = 0;
		pentry->queueentry.elapsed_wait = 0;
	}
}


/* ----------
 * pgstat_fetch_stat_queueentry() -
 *
 *	Support function for the SQL-callable pgstat* functions. Returns
 *	the collected statistics for one resource queue or NULL. NULL doesn't mean
 *	that the queue doesn't exist, it is just not yet known by the statistics
 *	system, so the caller is better off to report ZERO instead.
 * ----------
 */
PgStat_StatQueueEntry *
pgstat_fetch_stat_queueentry(Oid queueid)
{
	return (PgStat_StatQueueEntry *)
		pgstat_fetch_entry(PGSTAT_KIND_RESQUEUE, InvalidOid, queueid);
}
