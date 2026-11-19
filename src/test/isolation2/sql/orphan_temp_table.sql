-- Test orphan temp table on coordinator. 
-- Before the fix, when backend process panic on the segment, the temp table will be left on the coordinator.

-- create a temp table
1: CREATE TEMP TABLE test_temp_table_cleanup(a int);

-- panic on segment 0
1: SELECT gp_inject_fault('before_exec_scan', 'panic', dbid) FROM gp_segment_configuration WHERE role='p' AND content = 0;

-- trigger 'before_exec_scan' panic in ExecScan
1: SELECT * FROM test_temp_table_cleanup;

-- we should not see the temp table on the coordinator
1: SELECT oid, relname, relnamespace FROM pg_class where relname = 'test_temp_table_cleanup';
-- we should not see the temp namespace on the coordinator
1: SELECT count(*) FROM pg_namespace where (nspname like '%pg_temp_%' or nspname like '%pg_toast_temp_%') and oid > 16386;


-- the temp table is left on segment 0, it should be dropped by autovacuum later
0U: SELECT relname FROM pg_class where relname = 'test_temp_table_cleanup';

-- no temp table left on other segments
1U: SELECT oid, relname, relnamespace FROM pg_class where relname = 'test_temp_table_cleanup';

1: SELECT gp_inject_fault('before_exec_scan', 'reset', dbid) FROM gp_segment_configuration WHERE role='p' AND content = 0;

-- case 2: Test if temp namespace will be left if session exits during a long insert operation

2: CREATE TEMP TABLE test_temp_table_cleanup(a int);
2: BEGIN;
-- simulate a long insert query
2: SELECT gp_inject_fault('heap_insert', 'infinite_loop', '', '',
   'test_temp_table_cleanup', 1, 1, 0, dbid) FROM gp_segment_configuration
   WHERE content = 0 AND role = 'p';
2&: INSERT INTO test_temp_table_cleanup SELECT generate_series(1, 100);

-- trigger a panic on the segment
3: SELECT gp_inject_fault('create_function_fail', 'panic', dbid) FROM gp_segment_configuration WHERE role='p' AND content = 0;
3: CREATE FUNCTION my_function() RETURNS void AS $$ BEGIN END; $$ LANGUAGE plpgsql;

-- the insert query should have failed
2<:
2q:

3: CREATE TABLE ensure_segment_is_up(a int);
3: DROP TABLE ensure_segment_is_up;

3: SELECT gp_inject_fault('create_function_fail', 'reset', dbid) FROM gp_segment_configuration WHERE role='p' AND content = 0;
3: SELECT gp_inject_fault('heap_insert', 'reset', dbid) FROM gp_segment_configuration WHERE role='p' AND content = 0;
-- there shouldn't be any temporary namespaces left after the session quits
3: SELECT count(*) FROM pg_namespace where (nspname like '%pg_temp_%' or nspname like '%pg_toast_temp_%') and oid > 16386;
3q:
