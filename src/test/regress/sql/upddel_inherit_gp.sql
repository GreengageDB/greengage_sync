--
-- UPDATE and DELETE over an inheritance tree.
--
-- A single plan covers the whole target tree, with a single Motion on top of
-- it.  The members of an old-style inheritance tree may be distributed on
-- columns of their own, and may lay their columns out differently from the
-- table named in the statement, so each row has to be routed and reassembled
-- according to the relation it actually came from.  The tests below check the
-- resulting contents and, with misplaced_rows(), that every row sits on the
-- segment its own relation's distribution policy calls for.
--
create schema upddel_inherit_gp;
set search_path = upddel_inherit_gp;

--
-- Counts the rows of a table that are not on the segment its distribution
-- policy calls for.  Re-inserting the same rows into a table with the same
-- policy has to place them on the same segments, so whatever the EXCEPT ALL
-- leaves over is a misplaced row.  Deliberately independent of the number of
-- segments in the cluster.
--
-- The probe has to be filled from gp_dist_random() rather than from a plain
-- scan, to make sure the rows are actually redistributed to the correct
-- segments. A plain scan would just leave the misplaced rows on their wrong
-- segments, and wouldn't be able to report an error.
--
create function misplaced_rows(tab regclass) returns bigint as $$
declare
    result bigint;
begin
    execute format('create temp table misplaced_probe (like %s) %s',
                   tab, pg_get_table_distributedby(tab));
    execute format('insert into misplaced_probe select * from gp_dist_random(%L)',
                   tab);
    execute format('select count(*) from ('
                   'select x.gp_segment_id, x.* from only %s x'
                   ' except all '
                   'select p.gp_segment_id, p.* from misplaced_probe p) q', tab)
        into result;
    drop table misplaced_probe;
    return result;
end;
$$ language plpgsql;


--
-- 1. Members distributed on different columns.
--
create table pa (a int, b int, x text) distributed by (a);
create table pa_a (like pa) inherits (pa) distributed by (a);
create table pa_b (like pa) inherits (pa) distributed by (b);
create table src (a int, tag text) distributed by (a);

insert into pa   select g, g * 2, 'p' || g from generate_series(1, 6) g;
insert into pa_a select g, g * 2, 'a' || g from generate_series(7, 12) g;
insert into pa_b select g, g * 2, 'b' || g from generate_series(13, 18) g;
insert into src  select g, 'T' || g from generate_series(1, 18) g;

-- The join puts a Motion below the ModifyTable, so the Explicit Redistribute
-- on top has to bring every member's rows back to the segment they came from,
-- whichever column that member is distributed on.
explain (costs off)
update pa set x = 'J' || src.tag from src where pa.a = src.a;

update pa set x = 'J' || src.tag from src where pa.a = src.a;
select tableoid::regclass, * from pa order by a;
select misplaced_rows('pa'), misplaced_rows('pa_a'), misplaced_rows('pa_b');

-- The same for a DELETE.
explain (costs off) delete from pa using src where pa.a = src.a and src.a % 6 = 0;
delete from pa using src where pa.a = src.a and src.a % 6 = 0;
select tableoid::regclass, * from pa order by a;

-- No Motion at all: the scan of every member is in the same slice as the
-- ModifyTable, so the Explicit Redistribute can be elided.
explain (costs off) update pa set x = 'K' where b = 4;
update pa set x = 'K' where b = 4;
select tableoid::regclass, * from pa order by a;
select misplaced_rows('pa'), misplaced_rows('pa_a'), misplaced_rows('pa_b');


--
-- 2. Split updates over the same tree.
--
-- Changing "a" changes the distribution key of pa and pa_a but not of pa_b.
-- One SplitUpdate node serves all three; pa_b's rows are placed by "b", so
-- they stay where they are while the others move.
explain (costs off) update pa set a = a + 100;
update pa set a = a + 100;
select tableoid::regclass, * from pa order by a;
select misplaced_rows('pa'), misplaced_rows('pa_a'), misplaced_rows('pa_b');

-- Changing "b" is a distribution key change for pa_b alone, and it still
-- forces the split for the whole tree.
explain (costs off) update pa set b = b + 1000;
update pa set b = b + 1000;
select tableoid::regclass, * from pa order by a;
select misplaced_rows('pa'), misplaced_rows('pa_a'), misplaced_rows('pa_b');

-- Both keys at once, driven by a join.
explain (costs off) update pa set a = pa.a + 1, b = pa.b + 1 from src where pa.a - 100 = src.a;
update pa set a = pa.a + 1, b = pa.b + 1 from src where pa.a - 100 = src.a;
select tableoid::regclass, * from pa order by a;
select misplaced_rows('pa'), misplaced_rows('pa_a'), misplaced_rows('pa_b');

-- A subplan that provably returns nothing needs no SplitUpdate.
explain (costs off) update pa set a = 0 where a = 1 and a < 1;

-- RETURNING, and the same from a data-modifying CTE.
explain (costs off)
with u as (
    update pa set x = x || '.' returning tableoid::regclass as rel, a, b, x
)
select * from u order by a;

with u as (
    update pa set x = x || '.' returning tableoid::regclass as rel, a, b, x
)
select * from u order by a;

explain (costs off)
with d as (
    delete from pa where b % 4 = 0 returning tableoid::regclass as rel, a
)
select * from d order by a;

with d as (
    delete from pa where b % 4 = 0 returning tableoid::regclass as rel, a
)
select * from d order by a;

select misplaced_rows('pa'), misplaced_rows('pa_a'), misplaced_rows('pa_b');

-- ONLY takes the children back out of the statement.
explain (costs off) update only pa set x = x || '!';
update only pa set x = x || '!';
select tableoid::regclass, * from pa order by a;
explain (costs off) update only pa set a = a + 1;
update only pa set a = a + 1;
select tableoid::regclass, * from pa order by a;
explain (costs off) delete from only pa where b % 3 = 0;
delete from only pa where b % 3 = 0;
select tableoid::regclass, * from pa order by a;
select misplaced_rows('pa'), misplaced_rows('pa_a'), misplaced_rows('pa_b');


--
-- 3. Children with columns the parent does not have.
--
-- The subplan's targetlist is in the parent's layout, so the child's extra
-- columns have to travel beside it as a whole-row junk column, or they would
-- be lost -- both by a plain update, which writes a whole new tuple, and by a
-- split update, which deletes the row and inserts it again.  Only the members
-- that have such columns emit that column, so the rest have to cope with it
-- being NULL.
--
create table ex (a int, b int) distributed by (a);
create table ex_wide (a int, b int, extra text, more int)
    inherits (ex) distributed by (a);
create table ex_wide_b (a int, b int, extra text)
    inherits (ex) distributed by (b);

-- extra columns, a column order of its own, and its own distribution key
create table ex_odd (extra text, b int, more int, a int) distributed by (b);
alter table ex_odd inherit ex;

insert into ex        select g, g from generate_series(1, 4) g;
insert into ex_wide   select g, g, 'w' || g, g * 10 from generate_series(5, 8) g;
insert into ex_wide_b select g, g, 'v' || g from generate_series(9, 12) g;
insert into ex_odd    select 'y' || g, g, g * 10, g from generate_series(13, 16) g;

explain (verbose, costs off) update ex set b = b + 1;
update ex set b = b + 1;
select * from only ex order by a;
select * from ex_wide order by a;
select * from ex_wide_b order by a;
select * from ex_odd order by a;

explain (costs off) update ex set a = a + 100;
update ex set a = a + 100;
select * from only ex order by a;
select * from ex_wide order by a;
select * from ex_wide_b order by a;
select * from ex_odd order by a;
select misplaced_rows('ex'), misplaced_rows('ex_wide'),
       misplaced_rows('ex_wide_b'), misplaced_rows('ex_odd');

explain (costs off) delete from ex where a % 2 = 0;
delete from ex where a % 2 = 0;
select tableoid::regclass, * from ex order by a;


--
-- 4. A child distributed on a column the parent does not have.
--
create table kp (a int, b int) distributed by (a);
create table kp_own (a int, b int, k int) inherits (kp) distributed by (k);

insert into kp     select g, g from generate_series(1, 4) g;
insert into kp_own select g, g, g * 3 from generate_series(5, 8) g;

-- "b" is nobody's distribution key, so no split update.
explain (costs off) update kp set b = b + 1;
update kp set b = b + 1;
select * from kp order by a;

-- "a" is kp's key, so the statement splits.  kp_own's rows are placed by "k",
-- which this statement cannot reach, so they must not move.
explain (costs off) update kp set a = a + 100;
update kp set a = a + 100;
select * from kp order by a;
select misplaced_rows('kp'), misplaced_rows('kp_own');


--
-- 5. Children whose columns are laid out differently from the parent's.
--
create table ord (a int, b int, x text) distributed by (a);

-- reversed column order
create table ord_rev (x text, b int, a int) distributed by (b);
alter table ord_rev inherit ord;

-- a dropped column in the middle
create table ord_drop (a int, dead int, b int, x text) distributed by (b);
alter table ord_drop drop column dead;
alter table ord_drop inherit ord;

insert into ord      select g, g * 2, 'o' || g from generate_series(1, 4) g;
insert into ord_rev  select 'r' || g, g * 2, g from generate_series(5, 8) g;
insert into ord_drop select g, g * 2, 'd' || g from generate_series(9, 12) g;

explain (costs off) update ord set x = upper(x);
update ord set x = upper(x);
select tableoid::regclass, * from ord order by a;

-- "b" is the key of both children but not of the parent
explain (costs off) update ord set b = b + 1;
update ord set b = b + 1;
select tableoid::regclass, * from ord order by a;
select misplaced_rows('ord'), misplaced_rows('ord_rev'), misplaced_rows('ord_drop');

-- "a" is the parent's key only
explain (costs off) update ord set a = a + 100;
update ord set a = a + 100;
select tableoid::regclass, * from ord order by a;
select misplaced_rows('ord'), misplaced_rows('ord_rev'), misplaced_rows('ord_drop');

explain (costs off) delete from ord where a % 2 = 0;
delete from ord where a % 2 = 0;
select tableoid::regclass, * from ord order by a;


--
-- 6. A member whose distribution key sits at a different attribute number.
--
-- The changed columns are numbered in the nominal relation, so matching them
-- against a member's distribution key means translating them into that
-- member's own numbering first.  A dropped column shifts everything after it:
-- here the parent's "b" is attribute 2 and the child's is attribute 3.
--
-- The child has to be the only member keyed on "b".  If any member whose
-- numbering happens to agree with the parent's were also keyed on it, that one
-- would force the split on its own and the translation would go untested --
-- update_needs_split() stops at the first member that needs it.
--
create table shift (a int, b int, x text) distributed by (a);
create table shift_c (a int, dead int, b int, x text) distributed by (b);
alter table shift_c drop column dead;
alter table shift_c inherit shift;

insert into shift   select g, g * 2, 's' || g from generate_series(1, 4) g;
insert into shift_c select g, g * 2, 'c' || g from generate_series(5, 16) g;

-- "b" is the parent's attribute 2 and the child's attribute 3; only the child
-- is keyed on it, so only the translated answer forces the split
explain (costs off) update shift set b = b + 1;
update shift set b = b + 1;
select tableoid::regclass, * from shift order by a;
select misplaced_rows('shift'), misplaced_rows('shift_c');

-- "a" is the parent's key, and sits at attribute 1 in both
explain (costs off) update shift set a = a + 100;
update shift set a = a + 100;
select tableoid::regclass, * from shift order by a;
select misplaced_rows('shift'), misplaced_rows('shift_c');


--
-- 7. Multi-level inheritance.
--
create table ml1 (a int, b int) distributed by (a);
create table ml2 (a int, b int, mid text) inherits (ml1) distributed by (b);
create table ml3 (a int, b int, mid text, leaf int) inherits (ml2) distributed by (a);

insert into ml1 select g, g from generate_series(1, 3) g;
insert into ml2 select g, g, 'm' || g from generate_series(4, 6) g;
insert into ml3 select g, g, 'm' || g, g * 10 from generate_series(7, 9) g;

explain (costs off) update ml1 set b = b + 10;
update ml1 set b = b + 10;
select tableoid::regclass, * from ml1 order by a;
select * from only ml2 order by a;
select * from ml3 order by a;

explain (costs off) update ml1 set a = a + 100;
update ml1 set a = a + 100;
select tableoid::regclass, * from ml1 order by a;
select * from only ml2 order by a;
select * from ml3 order by a;
select misplaced_rows('ml1'), misplaced_rows('ml2'), misplaced_rows('ml3');

-- the middle of the tree as the target
explain (costs off) update ml2 set b = b + 1000;
update ml2 set b = b + 1000;
select tableoid::regclass, * from ml1 order by a;
select misplaced_rows('ml1'), misplaced_rows('ml2'), misplaced_rows('ml3');

explain (costs off) delete from ml1 where b > 1000;
delete from ml1 where b > 1000;
select tableoid::regclass, * from ml1 order by a;


--
-- 8. A randomly distributed member.
--
-- It has no distribution key to hash, so a split update has to re-insert its
-- rows on the segment they came from rather than pick one.
--
create table rnd (a int, b int) distributed by (a);
create table rnd_rand (like rnd) inherits (rnd) distributed randomly;

insert into rnd      select g, g from generate_series(1, 4) g;
insert into rnd_rand select g, g from generate_series(5, 8) g;

create temp table rnd_rand_before as
    select gp_segment_id as seg, b from rnd_rand distributed randomly;

explain (costs off) update rnd set a = a + 100;
update rnd set a = a + 100;
select * from rnd order by a;
select misplaced_rows('rnd');

-- the randomly distributed child's rows must not have moved
select count(*) from rnd_rand r join rnd_rand_before o using (b)
    where r.gp_segment_id <> o.seg;


--
-- 9. A replicated target.
--
create table rep (a int, b int) distributed replicated;
insert into rep select g, g from generate_series(1, 4) g;

explain (costs off) update rep set b = b + 1;
update rep set b = b + 1;
explain (costs off) update rep set a = a + 100 where b = 3;
update rep set a = a + 100 where b = 3;
select * from rep order by a;
explain (costs off) delete from rep where a > 100;
delete from rep where a > 100;
select * from rep order by a;

-- every segment has to hold every row
select count(*) from (
    select a, b, count(*) as c from gp_dist_random('rep') group by 1, 2
) s where s.c <> (select count(*) from gp_segment_configuration
                   where role = 'p' and content >= 0);


--
-- 10. An update trigger anywhere in the tree blocks a split update.
--
-- A split update would delete the row and insert it again behind the
-- trigger's back, so it is rejected even when the trigger is on a child.
--
create function trig_noop() returns trigger as $$
begin
    return new;
end;
$$ language plpgsql;

create table trg (a int, b int) distributed by (a);
create table trg_child (like trg) inherits (trg) distributed by (a);
create trigger trg_child_upd before update on trg_child
    for each row execute procedure trig_noop();

insert into trg       values (1, 1);
insert into trg_child values (2, 2);

-- not a distribution key change: allowed
explain (costs off) update trg set b = b + 1;
update trg set b = b + 1;
select tableoid::regclass, * from trg order by a;

-- distribution key change: rejected
explain (costs off) update trg set a = a + 1;
update trg set a = a + 1;


--
-- 11. Append-optimized members.
--
-- An append-optimized table cannot fetch a tuple by TID, so the plan has to
-- carry everything ModifyTable needs down to the segments.
--
create table ao (a int, b int, x text) distributed by (a);
create table ao_row (like ao) inherits (ao)
    with (appendonly = true) distributed by (a);
create table ao_col (like ao) inherits (ao)
    with (appendonly = true, orientation = column) distributed by (b);

insert into ao     select g, g, 'h' || g from generate_series(1, 3) g;
insert into ao_row select g, g, 'r' || g from generate_series(4, 6) g;
insert into ao_col select g, g, 'c' || g from generate_series(7, 9) g;

explain (verbose, costs off) update ao set x = x || '!';
update ao set x = x || '!';
select tableoid::regclass, * from ao order by a;

explain (costs off) update ao set a = a + 100;
update ao set a = a + 100;
select tableoid::regclass, * from ao order by a;
select misplaced_rows('ao'), misplaced_rows('ao_row'), misplaced_rows('ao_col');

explain (costs off) delete from ao where a % 2 = 1;
delete from ao where a % 2 = 1;
select tableoid::regclass, * from ao order by a;


--
-- 12. Partitioned tables.
--
-- Partitions all share their root's distribution policy, but they need not
-- share its column order, and a split update may have to move a row to
-- another partition as well as to another segment.
--
-- "a" is the partition key and "b" the distribution key, so the two can be
-- varied independently; "id" names a row without being either.
create table part (id int, a int, b int, x text)
    distributed by (b) partition by range (a);
create table part_1 partition of part for values from (1) to (10);
create table part_2 partition of part for values from (10) to (20);

-- a partition whose columns are stored in a different order
create table part_3 (x text, b int, a int, id int) distributed by (b);
alter table part attach partition part_3 for values from (20) to (30);

-- an append-optimized partition
create table part_4 partition of part for values from (30) to (40)
    with (appendonly = true);

-- a partition with a dropped column
create table part_5 (id int, dead int, a int, b int, x text) distributed by (b);
alter table part_5 drop column dead;
alter table part attach partition part_5 for values from (40) to (50);

insert into part select g, g, g, 'p' || g from generate_series(1, 49) g where g % 7 = 1;
select tableoid::regclass, * from part order by id;

-- same partition, same segment
explain (costs off) update part set x = x || '!' where id = 1;
update part set x = x || '!' where id = 1;
-- another segment, same partition
explain (costs off) update part set b = b + 1 where id = 8;
update part set b = b + 1 where id = 8;
-- another partition, same segment
explain (costs off) update part set a = 5 where id = 15;
update part set a = 5 where id = 15;
-- another partition and another segment at once, into the reordered partition
explain (costs off) update part set a = 25, b = b + 3 where id = 1;
update part set a = 25, b = b + 3 where id = 1;
-- ... into the append-optimized partition
update part set a = 35, b = b + 5 where id = 22;
-- ... and into the one with a dropped column
update part set a = 45, b = b + 7 where id = 36;
select tableoid::regclass, * from part order by id;
select misplaced_rows('part_1'), misplaced_rows('part_2'), misplaced_rows('part_3'),
       misplaced_rows('part_4'), misplaced_rows('part_5');

-- no partition takes the new row
explain (costs off) update part set a = a + 100 where id = 29;
update part set a = a + 100 where id = 29;

-- the same, but as a split update
explain (costs off) update part set a = a + 100, b = b + 1 where id = 29;
update part set a = a + 100, b = b + 1 where id = 29;

explain (costs off) delete from part where a > 20;
delete from part where a > 20;
select tableoid::regclass, * from part order by id;


--
-- 13. A partitioned table with a dropped column.
--
-- Worth a section of its own because ORCA builds its ModifyTable nodes
-- directly rather than through createplan.c, and a dropped column is where
-- the root's column layout and a partition's part company.
--
create table orca_p (a int, dead int, b int, x text)
    distributed by (a) partition by range (a);
create table orca_p1 partition of orca_p for values from (1) to (10);
create table orca_p2 partition of orca_p for values from (10) to (20);
alter table orca_p drop column dead;

insert into orca_p select g, g, 'o' || g from generate_series(1, 19) g where g % 4 = 1;
select tableoid::regclass, * from orca_p order by a;

explain (costs off) update orca_p set x = x || '#';
update orca_p set x = x || '#';
select tableoid::regclass, * from orca_p order by a;

explain (costs off) update orca_p set b = b + 1 where a = 5;
update orca_p set b = b + 1 where a = 5;
explain (costs off) update orca_p set a = a + 10 where a < 10;
update orca_p set a = a + 10 where a < 10;
select tableoid::regclass, * from orca_p order by a;
select misplaced_rows('orca_p1'), misplaced_rows('orca_p2');

explain (costs off) delete from orca_p where b % 2 = 1;
delete from orca_p where b % 2 = 1;
select tableoid::regclass, * from orca_p order by a;

-- back to the old-style inheritance tree, one more time
explain (costs off) update pa set x = x || '~';
update pa set x = x || '~';
explain (costs off) update pa set a = a + 1;
update pa set a = a + 1;
select tableoid::regclass, * from pa order by a;
select misplaced_rows('pa'), misplaced_rows('pa_a'), misplaced_rows('pa_b');

drop schema upddel_inherit_gp cascade;
