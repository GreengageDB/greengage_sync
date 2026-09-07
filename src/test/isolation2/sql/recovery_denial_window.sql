-- Test the connection-denial contract of a segment in the
-- pre-walreceiver recovery window (PM_RECOVERY -> CAC_NOTCONSISTENT).
-- Since upstream df9384492b8 this state answers "the database system is
-- not (yet) accepting connections"; GGDB's FTS probe and gang-creation
-- retry logic recognize that wording and parse the replayed-LSN detail,
-- and FTS/fault-injector connections must be let through to a mirror in
-- this state.
--
-- The window is held open deterministically with recovery_min_apply_delay.
-- The delay only takes effect after consistency is reached (see
-- recoveryApplyDelay() in xlog.c), so the mechanism is: on restart the
-- mirror reaches consistency early, then the delay stalls replay of the
-- backlog of (post-consistency) commit records.  Because a mirror runs
-- with hot_standby off it never advances to PM_HOT_STANDBY; it stays in
-- PM_RECOVERY -> CAC_NOTCONSISTENT, and the stalled replay keeps local WAL
-- from draining, so the walreceiver (and with it the CAC_MIRROR_READY fast
-- path) never starts for the duration of the delay.
--
-- Like its pg_rewind siblings, this assumes a single-host cluster
-- (pg_ctl runs against the mirror's datadir from here).  On a cluster
-- without mirrors every mirror-dependent step degrades to a no-op.

-- Heal any leftover state from an interrupted earlier run (strip the
-- delay and reload the mirror if it is running), then save the
-- mirror's coordinates.  An empty state file means "no mirror: skip";
-- a failure of the query itself fails the test rather than skipping.
!\retcode STATE=./results/recovery_denial_window_mdir.${PGPORT}; rm -f ${STATE}; psql -At -p ${PGPORT} -d postgres -c "select datadir from gp_segment_configuration where content=0 and role='m'" > ${STATE} || exit 1; if [ -s ${STATE} ]; then MDIR=$(cat ${STATE}); sed -i "/recovery_min_apply_delay/d" ${MDIR}/postgresql.auto.conf; pg_ctl -D ${MDIR} reload > /dev/null 2>&1 || true; fi;

create table t_denial_window(a int);
insert into t_denial_window select generate_series(1,1000);

-- Stall apply on the running mirror.  The window check below is the
-- confirmation that the setting took effect.  The delay is kept short
-- enough that even a run interrupted before the cleanup leaves a mirror
-- that catches up by itself.
!\retcode STATE=./results/recovery_denial_window_mdir.${PGPORT}; if [ -s ${STATE} ]; then MDIR=$(cat ${STATE}); echo "recovery_min_apply_delay = '180s'" >> ${MDIR}/postgresql.auto.conf; pg_ctl -D ${MDIR} reload; fi;
insert into t_denial_window select generate_series(1,20000);

-- Restart the mirror into the held-open window.
!\retcode STATE=./results/recovery_denial_window_mdir.${PGPORT}; if [ -s ${STATE} ]; then sleep 2; MDIR=$(cat ${STATE}); pg_ctl -D ${MDIR} restart -w -m fast -l /dev/null; fi;

-- 1. The denial message must carry both the wording and the
--    recovery-progress detail that checkIfFailedDueToNormalRestart()
--    and segment_failure_due_to_recovery() depend on.
!\retcode STATE=./results/recovery_denial_window_mdir.${PGPORT}; if [ -s ${STATE} ]; then MPORT=$(psql -At -p ${PGPORT} -d postgres -c "select port from gp_segment_configuration where content=0 and role='m'"); msg=; for i in $(seq 30); do msg=$(PGOPTIONS='-c gp_role=utility' psql -p ${MPORT} -d postgres -c 'select 1' 2>&1); echo "${msg}" | grep -q "accepting connections" && break; sleep 1; done; echo "${msg}" | grep -q "accepting connections" && echo "${msg}" | grep -q "last replayed record at"; fi;

-- 2. The FTS/fault-injector connection must be let through to the
--    mirror while it sits in this window.  A read-only status probe of
--    an unset fault answers "not set" if and only if the connection
--    reached the mirror's fault handler.
!\retcode STATE=./results/recovery_denial_window_mdir.${PGPORT}; if [ -s ${STATE} ]; then psql -p ${PGPORT} -d isolation2test -c "select gp_inject_fault('after_xlog_redo_noop','status',dbid) from gp_segment_configuration where content=0 and role='m'" 2>&1 | grep -q "not set"; fi;

-- Release the window and restore the mirror.
!\retcode STATE=./results/recovery_denial_window_mdir.${PGPORT}; if [ -s ${STATE} ]; then MDIR=$(cat ${STATE}); sed -i "/recovery_min_apply_delay/d" ${MDIR}/postgresql.auto.conf; pg_ctl -D ${MDIR} restart -w -m fast -l /dev/null; fi; rm -f ${STATE};
select wait_until_all_segments_synchronized();
drop table t_denial_window;
