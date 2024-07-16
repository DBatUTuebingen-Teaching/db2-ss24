-- Demonstrate the on-demand evaluation of query plans
-- (continuation of experiment [***] in plans-monetdb.txt)

-- ➋ PostgreSQL: prepare input table

DROP TABLE IF EXISTS hundred;

CREATE TABLE hundred (i int);
INSERT INTO hundred(i)
  SELECT i
  FROM   generate_series(1, 100) AS i;

\d hundred


-- Evaluate large cross-products (demand-driven pipelining)

SELECT 42 AS fortytwo
FROM   hundred AS h1, hundred AS h2, hundred AS h3
LIMIT 1;

SELECT 42 AS fortytwo
FROM   hundred AS h1, hundred AS h2, hundred AS h3, hundred AS h4
LIMIT 1;

SELECT 42 AS fortytwo
FROM   hundred AS h1, hundred AS h2, hundred AS h3, hundred AS h4, hundred AS h5
LIMIT 1;

-- Note 'rows = 1' annotations on all plan operators: no operator processes
-- more than a single row, regardless of length of crossproduct chain
EXPLAIN (ANALYZE, BUFFERS, COSTS FALSE)
  SELECT 42 AS fortytwo
  FROM   hundred AS h1, hundred AS h2, hundred AS h3, hundred AS h4, hundred AS h5
  LIMIT 1;


-----------------------------------------------------------------------
-- Demonstrate demand-driven evaluation and the NON-evaluation of
-- parts of a query plan

-- ➊ Check input tables
\d one

\d many


-- ➋ Join query in which one leg yields the empty table ⇒ other leg
--   not evaluated at all
set enable_hashjoin = off;

-- Watch out for the '(never executed)' annotations
EXPLAIN (VERBOSE, ANALYZE)
  SELECT o.a / 0
  FROM   one AS o, many AS m
  WHERE  o.c = m.c
    AND  m.b = 'Ben Kenobi';  -- ← never satisfied ⇒ input leg 'many' yields no rows

reset enable_hashjoin;

-----------------------------------------------------------------------
-- Demonstrate how response and evaluation may differ/coincide for
-- different (non-)blocking operator kinds

-- ➊ Check input table
\d many


-- ➋ Seq Scan w/ Filter (fully pipelined)
EXPLAIN (ANALYZE, COSTS false)
  SELECT m.b
  FROM   many AS m
  WHERE  m.a > 42;


-- ➌ Sort Filter (blocking)
EXPLAIN (ANALYZE, COSTS false)
  SELECT m.b
  FROM   many AS m
  WHERE  m.a > 42
  ORDER BY m.b;


-- ➍ Aggregate (blocking, result tiny)
EXPLAIN (ANALYZE, COSTS false)
  SELECT COUNT(m.b)
  FROM   many AS m
  WHERE  m.a > 42;


-- ➎ Grouped Aggregate over sorted input
--   (⚠️ first group(s) delivered BEFORE blocking Sort is done)
set enable_hashagg = off;

EXPLAIN (ANALYZE, COSTS false)
 SELECT m.c, COUNT(m.b)
 FROM   many AS m
 WHERE  m.a > 42
 GROUP BY m.c;

reset enable_hashagg;


-----------------------------------------------------------------------
-- Demonstrate the SQL-level Volcano-style cursor interface

-- ➊ Check input tables
\d one

\d many

set enable_hashagg = off;


-- The plan for this query features a blocking SORT operator
-- to implement SQL's DISTINCT:
EXPLAIN (ANALYZE)
  SELECT DISTINCT o.a, o.b || m.b AS md5
  FROM   one AS o, many AS m
  WHERE o.a = m.a;


-- ➋ Declare/fetch/close cursor for join query (within a SQL transaction)

\set ON_ERROR_ROLLBACK interactive
BEGIN;

DECLARE pipeline SCROLL CURSOR FOR
  SELECT DISTINCT o.a, o.b || m.b AS md5
  FROM   one AS o, many AS m
  WHERE o.a = m.a;

-- Observe widely varying evaluation times for the following two FETCHes
FETCH NEXT pipeline;

FETCH NEXT pipeline;

FETCH FORWARD 3 pipeline;

FETCH BACKWARD 2 pipeline;

CLOSE pipeline;

COMMIT;


-- The following query reveals the internal implementation of UNION ALL

-- NB. Query will generate six rows (i = 1…6)
EXPLAIN
  SELECT i FROM generate_series(1,3) AS i
    UNION ALL
  (SELECT i
   FROM   generate_series(5000000,4,-1) AS i
   ORDER BY i
   LIMIT 3);

BEGIN;

DECLARE pipeline CURSOR FOR
  SELECT i FROM generate_series(1,3) AS i
    UNION ALL
  (SELECT i
   FROM   generate_series(5000000,4,-1) AS i
   ORDER BY i
   LIMIT 3);

-- Try to explain the observed evaluation times for these six FETCHes
FETCH NEXT pipeline;
FETCH NEXT pipeline;
FETCH NEXT pipeline;
FETCH NEXT pipeline;
FETCH NEXT pipeline;
FETCH NEXT pipeline;

CLOSE pipeline;

COMMIT;
