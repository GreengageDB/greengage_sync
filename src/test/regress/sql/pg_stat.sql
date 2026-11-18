set optimizer to off;
drop table  if exists pg_stat_test;
create table pg_stat_test(a int);

select
    schemaname, relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch, n_tup_ins, n_tup_upd,
    n_tup_del, n_tup_hot_upd, n_live_tup, n_dead_tup
from pg_stat_all_tables where relname = 'pg_stat_test';
select
    schemaname, relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch, n_tup_ins, n_tup_upd,
    n_tup_del, n_tup_hot_upd, n_live_tup, n_dead_tup
from pg_stat_user_tables where relname = 'pg_stat_test';
select
    schemaname, relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
from pg_stat_all_indexes where relname = 'pg_stat_test';
select
    schemaname, relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
from pg_stat_user_indexes where relname = 'pg_stat_test';

begin; -- make analyze same transcation with insert to avoid double the pgstat causes by unorder message read.
insert into pg_stat_test select * from generate_series(1, 100);
analyze pg_stat_test;
commit;

create index pg_stat_user_table_index on pg_stat_test(a);

select count(*) from pg_stat_test;

delete from pg_stat_test where a < 10;

update pg_stat_test set a = 1000 where a > 90;

set enable_seqscan to off;

select * from pg_stat_test where a = 1;

reset enable_seqscan;

-- PostgreSQL 15 keeps cumulative statistics in shared memory instead of
-- sending them to a collector, and every backend flushes its own pending
-- counters at most once per PGSTAT_MIN_INTERVAL, retrying once it has been
-- idle for PGSTAT_IDLE_INTERVAL (10s).  The wait therefore has to come after
-- the query whose counters are read below, not before it: ahead of it, the
-- index scan's own counters are still pending when they are read.
--
-- Greengage: for a user table the pg_stat_* views read each segment's shared
-- statistics through gp_dist_random(), and the sequential scan of the UPDATE
-- above is pending in this session's writer gang, which gets no further
-- command.  pg_stat_force_next_flush() dispatched to the segments only ever
-- reaches the reader gangs, so it cannot flush that one; waiting past
-- PGSTAT_IDLE_INTERVAL flushes every backend of the session, which is what
-- makes all four reads below settled.
select pg_sleep(11);

select
    schemaname, relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch, n_tup_ins, n_tup_upd,
    n_tup_del, n_tup_hot_upd, n_live_tup, n_dead_tup, n_mod_since_analyze
from pg_stat_all_tables where relname = 'pg_stat_test';
select
    schemaname, relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch, n_tup_ins, n_tup_upd,
    n_tup_del, n_tup_hot_upd, n_live_tup, n_dead_tup, n_mod_since_analyze
from pg_stat_user_tables where relname = 'pg_stat_test';
select
    schemaname, relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
from pg_stat_all_indexes where relname = 'pg_stat_test';
select
    schemaname, relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
from pg_stat_user_indexes where relname = 'pg_stat_test';

reset optimizer;
