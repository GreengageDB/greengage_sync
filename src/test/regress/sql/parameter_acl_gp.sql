--
-- GGDB: privileges on configuration parameters (GRANT ... ON PARAMETER) on a
-- cluster.
--
-- pg_parameter_acl is a shared catalog whose rows carry an OID, and GRANT is
-- re-executed on every segment.  So each node creates the row itself, and all
-- of them have to end up with the same row under the same OID: pg_shdepend
-- refers to it by OID, and DROP OWNED and REVOKE look it up again on each
-- node separately.
--

-- One line per granted privilege.  The row has to be present on the
-- coordinator and on every primary, under one and the same OID.
CREATE VIEW parameter_acl_gp_nodes AS
SELECT s.parname, s.grantee::regrole AS grantee, s.privilege_type,
       count(DISTINCT s.paroid) AS distinct_oids,
       count(*) = (SELECT count(*) FROM gp_segment_configuration
                   WHERE role = 'p') AS on_every_node
FROM (SELECT p.oid AS paroid, p.parname, a.grantee, a.privilege_type
        FROM pg_parameter_acl p, aclexplode(p.paracl) a
      UNION ALL
      SELECT p.oid, p.parname, a.grantee, a.privilege_type
        FROM gp_dist_random('pg_parameter_acl') p, aclexplode(p.paracl) a) s
WHERE s.grantee::regrole::text LIKE 'regress_paracl%'
GROUP BY 1, 2, 3;

-- The pg_shdepend entries of those rows.  A segment that had invented an OID
-- of its own would not join with the coordinator's pg_parameter_acl here.
CREATE VIEW parameter_acl_gp_shdep AS
SELECT p.parname, d.refobjid::regrole AS grantee, d.deptype,
       count(*) = (SELECT count(*) FROM gp_segment_configuration
                   WHERE role = 'p') AS on_every_node
FROM (SELECT objid, refobjid, deptype FROM pg_shdepend
       WHERE classid = 'pg_parameter_acl'::regclass
      UNION ALL
      SELECT objid, refobjid, deptype FROM gp_dist_random('pg_shdepend')
       WHERE classid = 'pg_parameter_acl'::regclass) d
     JOIN pg_parameter_acl p ON p.oid = d.objid
WHERE d.refobjid::regrole::text LIKE 'regress_paracl%'
GROUP BY 1, 2, 3;

-- Reads a setting in the process that runs the slice.  current_setting() is
-- stable and would be evaluated once, on the coordinator.
CREATE FUNCTION parameter_acl_gp_setting(name text) RETURNS text
VOLATILE LANGUAGE plpgsql AS
$$ BEGIN RETURN current_setting(name); END $$;

CREATE TABLE parameter_acl_gp_t (a int, b int) DISTRIBUTED BY (a);
INSERT INTO parameter_acl_gp_t SELECT g, g FROM generate_series(1, 100) g;
GRANT SELECT ON parameter_acl_gp_t TO PUBLIC;

CREATE ROLE regress_paracl_u1;
CREATE ROLE regress_paracl_u2;

-- The first grant on a parameter creates the row
GRANT SET ON PARAMETER log_duration TO regress_paracl_u1;
SELECT * FROM parameter_acl_gp_nodes ORDER BY 1, 2, 3;
SELECT * FROM parameter_acl_gp_shdep ORDER BY 1, 2, 3;

-- A further grant updates it, whatever the spelling of the name
GRANT ALTER SYSTEM ON PARAMETER "Log_Duration" TO regress_paracl_u2;

-- Several parameters in one statement: one named by its historical alias, one
-- a placeholder of an extension that is loaded nowhere
GRANT SET ON PARAMETER log_executor_stats, sort_mem, regress_paracl.knob
	TO regress_paracl_u1;
SELECT * FROM parameter_acl_gp_nodes ORDER BY 1, 2, 3;

-- A rolled back grant leaves nothing behind on any node
BEGIN;
GRANT SET ON PARAMETER log_statement_stats TO regress_paracl_u1;
ROLLBACK;

-- Neither does one undone by a subtransaction, while the grant that follows
-- it in the same transaction stays
DO $$
BEGIN
	BEGIN
		GRANT SET ON PARAMETER log_parser_stats TO regress_paracl_u1;
		RAISE EXCEPTION 'undo';
	EXCEPTION WHEN OTHERS THEN
		NULL;
	END;
	GRANT SET ON PARAMETER log_statement_stats TO regress_paracl_u2;
END $$;
SELECT * FROM parameter_acl_gp_nodes ORDER BY 1, 2, 3;

-- The granted parameter can be set and the segments apply it too; the other
-- one stays out of reach
SET SESSION AUTHORIZATION regress_paracl_u1;
SET log_duration = on;
SELECT count(*) AS rows_scanned_with_it_on FROM parameter_acl_gp_t
WHERE parameter_acl_gp_setting('log_duration') = 'on';
SET log_planner_stats = on;
RESET log_duration;
RESET SESSION AUTHORIZATION;

-- A role that logs in for real, so that the segments see an ordinary user
-- too.  The session has no gangs yet when the parameter is set; the ones the
-- join brings up have to learn the value from their startup options.
\! echo "local all regress_paracl_login trust" >> $COORDINATOR_DATA_DIRECTORY/pg_hba.conf
SELECT pg_reload_conf();
CREATE ROLE regress_paracl_login LOGIN;
GRANT SET ON PARAMETER log_duration TO regress_paracl_login;
\set paracl_superuser :USER
\c - regress_paracl_login
SET log_duration = on;
SELECT count(*) AS rows_joined_with_it_on
FROM (SELECT b FROM parameter_acl_gp_t
      WHERE parameter_acl_gp_setting('log_duration') = 'on') x
     JOIN parameter_acl_gp_t y ON x.b = y.a
WHERE parameter_acl_gp_setting('log_duration') = 'on';
\c - :paracl_superuser
\! sed -i '/regress_paracl_login/d' $COORDINATOR_DATA_DIRECTORY/pg_hba.conf
SELECT pg_reload_conf();
DROP OWNED BY regress_paracl_login;
DROP ROLE regress_paracl_login;

-- Revoking the last privilege removes the row everywhere
REVOKE SET ON PARAMETER log_statement_stats FROM regress_paracl_u2;
-- Revoking what was never granted does not create one
REVOKE SET ON PARAMETER log_planner_stats FROM regress_paracl_u2;
SELECT * FROM parameter_acl_gp_nodes ORDER BY 1, 2, 3;

-- DROP OWNED finds the rows through pg_shdepend on each node
DROP OWNED BY regress_paracl_u2;
SELECT * FROM parameter_acl_gp_nodes ORDER BY 1, 2, 3;
DROP OWNED BY regress_paracl_u1;
SELECT * FROM parameter_acl_gp_nodes ORDER BY 1, 2, 3;
SELECT * FROM parameter_acl_gp_shdep ORDER BY 1, 2, 3;
SELECT count(*) AS rows_left FROM
	(SELECT parname FROM pg_parameter_acl
	 UNION ALL
	 SELECT parname FROM gp_dist_random('pg_parameter_acl')) s
WHERE parname IN ('log_duration', 'log_executor_stats', 'work_mem',
				  'regress_paracl.knob', 'log_statement_stats',
				  'log_parser_stats', 'log_planner_stats');

DROP ROLE regress_paracl_u1, regress_paracl_u2;
DROP TABLE parameter_acl_gp_t;
DROP FUNCTION parameter_acl_gp_setting(text);
DROP VIEW parameter_acl_gp_nodes, parameter_acl_gp_shdep;
