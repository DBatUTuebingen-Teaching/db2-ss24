-----------------------------------------------------------------------
-- Sorting in PostgreSQL


-- Recreate and populate playground table "indexed",
-- rename primary key index to "indexed_a"
DROP TABLE IF EXISTS indexed;
CREATE TABLE indexed (a int PRIMARY KEY,
                      b text,
                      c numeric(3,2));
ALTER INDEX indexed_pkey RENAME TO indexed_a;

INSERT INTO indexed(a,b,c)
        SELECT i, md5(i::text), sin(i)
        FROM   generate_series(1,1000000) AS i;

ANALYZE indexed;

\d indexed

-----------------------------------------------------------------------
-- Sort is an ubiquitous plan operator used in ORDER BY, DISTINCT,
-- GROUP BY, (merge) join, window functions, ...

-- Focus is on sorting in this experiment
set enable_hashagg  = off;
set enable_hashjoin = off;
set enable_memoize  = off;

-- Query ➊: ORDER BY

EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c;


-- Query ➋: DISTINCT

EXPLAIN (VERBOSE, ANALYZE)
  SELECT DISTINCT i.c
  FROM   indexed AS i;


-- Query ➌: GROUP BY

EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.c, SUM(i.a) AS s
  FROM   indexed AS i
  GROUP BY i.c;


-- Query ➍: merge join

EXPLAIN (VERBOSE, ANALYZE)
  SELECT DISTINCT i1.a
  FROM   indexed AS i1,
         indexed AS i2
  WHERE  i1.a = i2.c :: int;


-- Query ➎ (not on slide): window aggregate

EXPLAIN (VERBOSE, ANALYZE)
 SELECT i.c, SUM(i.a) OVER (ORDER BY i.c ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS w
 FROM   indexed AS i;


-- Using column "a" (instead of "c") as the sorting/grouping/join
-- criterion leads PostgreSQL to use a sorted Index (Only) Scan instead
-- of the Sort plan operator.  For example:

-- Query ➊ (sorting criterion "c" → "a")
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.a;         -- 🠴 i.a instead of i.c

-- Query ➋ ("c" → "a")
EXPLAIN (VERBOSE, ANALYZE)
  SELECT DISTINCT i.a   -- 🠴 i.a instead of i.c
  FROM   indexed AS i;

-- Query ➌ ("c" → "a")
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.a, SUM(i.c) AS s
  FROM   indexed AS i
  GROUP BY i.a;         -- 🠴 i.a instead of i.c


reset enable_hashagg;
reset enable_hashjoin;
reset enable_memoize;

-----------------------------------------------------------------------
-- PostgreSQL chooses sort implementations based on
-- memory constraints/availability


-- ➊ Evaluate query under tight memory constraints
show work_mem;

EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c;


-- ➋ Re-valuate query with plenty of RAM-based temporary working memory
set work_mem = '1GB';

EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c;

reset work_mem;

-----------------------------------------------------------------------
-- Grouping in PostgreSQL

-- Switch from hashing to sorting when work_mem becomes scarce or when
-- the estimated number of groups becomes (too) large.


-- ➊ Prepare table grouped, start off with default work_mem

DROP TABLE IF EXISTS grouped;
CREATE TABLE grouped (a int, g int);

INSERT INTO grouped (a, g)
  SELECT i AS a, i % 10000 AS g            -- 10⁴ groups
  FROM   generate_series(1,1000000) AS i;  -- 10⁶ rows

ANALYZE grouped;

\d grouped


show work_mem;

-- ➋ Perform grouping with plenty of work_mem

EXPLAIN (VERBOSE, ANALYZE)
  SELECT g.g, SUM(g.a) AS s
  FROM   grouped AS g
  GROUP BY g.g;


-- ➌ Repeat grouping with scarce work_mem

set work_mem = '64kB';

EXPLAIN (VERBOSE, ANALYZE)
  SELECT g.g, SUM(g.a) AS s
  FROM   grouped AS g
  GROUP BY g.g;


-- ➍ Group count 𝐺 is conservatively overestimated unless truly obvious for the system

EXPLAIN (VERBOSE, ANALYZE)
  SELECT g.g % 2, SUM(g.a) AS s
  FROM   grouped AS g
  GROUP BY g.g % 2;     -- 🠴 will create three groups max, goes undetected by PostgreSQL :-(


EXPLAIN (VERBOSE, ANALYZE)
  SELECT g.g % 2 = 0, SUM(g.a) AS s
  FROM   grouped AS g
  GROUP BY g.g % 2 = 0;  -- 🠴 creates a Boolean, this IS detected by PostgreSQL (|dom(bool)| = 2)


reset work_mem;

-----------------------------------------------------------------------
-- Parallel grouping and aggregation for query Q10.
-- Works for distributive aggregate SUM/+, does not work for
-- array_agg/||.


-- ➊ Enable generation of parallel plans
--   (⚠️ this is supposed to be disabled in the lecture)

set max_parallel_workers = default;             -- = 8
set max_parallel_workers_per_gather = default;  -- = 8


-- ➋ Parallel grouping for SUM

EXPLAIN (VERBOSE, ANALYZE)
  SELECT g.g, SUM(g.a) AS s       -- 10⁴ groups
  FROM   grouped AS g             -- 10⁶ rows
  GROUP BY g.g;


-- ➌ Check aggregates and their finalize operations (for type int)
--   (aggregates that can be used in parallel/partial mode [missing: array_agg, ...])

SELECT a.aggfnoid, a.aggcombinefn, a.agginitval, t.typname
FROM   pg_aggregate AS a, pg_type AS t
WHERE  a.aggcombinefn <> 0 and a.aggkind = 'n'
AND    a.aggtranstype = t.oid AND t.typname LIKE '%int_';


-- ➍ Plans with non-distributive aggregates cannot be //ized this easily,
--   example: array_agg/||
--
--   array_agg({1,3,5,2,4,6} ORDER BY x)
--    ≠
--   array_agg({1,3,5} ORDER BY x)||  array_agg({2,4,6} ORDER BY x)

SELECT array_agg(x ORDER BY x) AS xs
FROM   generate_series(1, 10) AS x;

-- ≠

SELECT (
  (SELECT array_agg(x ORDER BY x) AS xs
   FROM   generate_series(1, 10) AS x
   WHERE  x % 2 = 0)
    ||
  (SELECT array_agg(x ORDER BY x) AS xs
   FROM   generate_series(1, 10) AS x
   WHERE  NOT(x % 2 = 0))
) AS xs;

-- Thus, NO //ism for this variant of query Q10

EXPLAIN (VERBOSE, ANALYZE)
  SELECT g.g, array_agg(g.a ORDER BY g.a) AS s   -- 10⁴ groups
  FROM   grouped AS g                            -- 10⁶ rows
  GROUP BY g.g;


set max_parallel_workers_per_gather = 0;
set max_parallel_workers = 0;

-----------------------------------------------------------------------

