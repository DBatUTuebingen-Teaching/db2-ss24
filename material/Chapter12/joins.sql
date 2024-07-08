-- Create and populate a join "playground":
-- (one-to-many (1:100) relationship between tables "one" and "many":
--  one row of table "one" joins with up to 100 rows of table "many")
--
-- Sample join predicates:
-- 1. one.a = many.a               (index-supported)
-- 2. md5(one.a) = one.b || many.b (||: string concat)

DROP TABLE IF EXISTS one CASCADE;
DROP TABLE IF EXISTS many;

CREATE TABLE one  (a int PRIMARY KEY,
                   b text,
                   c int);             -- # of join partners in "many"
CREATE TABLE many (a int NOT NULL,
                   b text,
                   c int NOT NULL,     -- this is join partner #c
                   PRIMARY KEY (a,c),
                   FOREIGN KEY (a) REFERENCES one(a));

ALTER INDEX one_pkey RENAME TO one_a;
ALTER INDEX many_pkey RENAME TO many_a_c;

-- |one| = 10000
INSERT INTO one(a,b,c)
  SELECT i, left(md5(i::text), 16), random() * (100 + 1)    -- 1:100 relationship
  FROM   generate_series(1, 10000) AS i;

-- |many| expected to be ≈ 50 × 10000 = 500000
INSERT INTO many(a,b,c)
  SELECT o.a, right(md5(o.a::text), 16), i
  FROM   one AS o, LATERAL generate_series(0, o.c - 1) AS i;


ANALYZE one;
ANALYZE many;

-- expected to be ≈ 50
SELECT avg(o.c) AS "average # of partners"
FROM   one AS o;

TABLE one
ORDER BY a
LIMIT 10;

TABLE many
ORDER BY a, c
LIMIT 10;

-----------------------------------------------------------------------
-- Demonstrate the beneficial effect of Materialize in Nested Loops Join

-- ➊ Input tables
\d one

\d many


-- ➋ Evaluate Nested Loop Join with Materialize (NB choice of outer vs inner)
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.b < m.b AND m.c < 2 AND o.c < 2;


-- ➌ Evaluate Nested Loop Join without Materialize (NB choice of outer vs inner)
set enable_material = off;

EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.b < m.b AND m.c < 2 AND o.c < 2;

reset enable_material;


-----------------------------------------------------------------------
-- Demonstrate the use of Index Nested Loop Join

-- ➊ Check indexes on table many
\d many


-- ➋ Perform index nested loop join (predicate m.a < o.c is supported by index many_a_c)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  m.a < o.c AND o.b < 'a';
                    -- ^^^^^^^^^ added to keep result small


-- ➌ ⚠️ Don't confuse the above with this plan which also uses Nested Loop Join + Index Scan
--   (see Materialize, index does not evaluate the join predicate)
set enable_memoize = off;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  m.c < o.c AND m.a < 42;

reset enable_memoize;

-----------------------------------------------------------------------
-- Merge Join: sort order on inputs can be establish in a variety of ways

-- ➊ Check input tables one, many
\d one

\d many

ANALYZE one;
ANALYZE many;

set enable_hashjoin = off;
set enable_nestloop = off;

-- ➋ Merge Join + Index Scan (many) + Sort (one)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT o.a, o.b AS b1, m.b AS b2   -- replace m.b by m.c: Index Scan → Index Only Scan
  FROM   one AS o, many AS m
  WHERE  o.c = m.a;                  -- sort on m.a supported by index many_a_c


-- ➌ Carefully assess sort order of index scan to decide whether Sort is required

EXPLAIN (VERBOSE, ANALYZE)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.c = m.c and m.a < 2;  -- m.a < 2 supported by index many_a_c but output
                                 -- will NOT be sorted by m.c ⇒ Sort required

EXPLAIN (VERBOSE, ANALYZE)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.c = m.c and m.a = 2;  -- m.a = 2 support by index many_a_c, index scans a = 2 group,
                                 -- output WILL be sorted by m.c ⇒ no Sort required
reset enable_hashjoin;
reset enable_nestloop;

-----------------------------------------------------------------------
-- Demonstrate the placement of Materialize above right subplan to
-- support the re-scanning.

-- ➊ Subplan uses disk-based sort ⇒ use Materialize to support re-scanning of sort output
set enable_hashjoin = off;
set enable_nestloop = off;
show work_mem;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.a = m.c;


-- ➋ Increased work_mem to enable in-memory sort ⇒ resulting buffer supports re-scanning, no Materialize needed
set work_mem = '64MB';  -- sufficient work memory to enable in-memory sort

EXPLAIN (VERBOSE, ANALYZE)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.a = m.c;

reset enable_hashjoin;
reset enable_nestloop;
reset work_mem;


-----------------------------------------------------------------------
-- Demonstrate that PostgreSQL tracks interesting orders that
-- have influence on subplans (even if these subplans themselves
-- do not benefit).  Overall plan cost improves.

-- ➊ No interesting order: use Hash Join (delivers rows in arbitrary order)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT o.a, o.b || m.b AS b
  FROM   one AS o, many AS m
  WHERE  o.a = m.a;

-- ➋ Interesting order o.a that coincides with join condition: use Merge Join
EXPLAIN (VERBOSE, ANALYZE)
  SELECT o.a, o.b || m.b AS b
  FROM   one AS o, many AS m
  WHERE  o.a = m.a
  ORDER BY o.a;             -- or: ORDER BY m.a

-----------------------------------------------------------------------
-- Demonstrate that PostgreSQL chooses Merge Join if the join
-- inputs are large (in the example below, the output has 1000 rows
-- only and thus is small) AND at least one join criterion is unique (thus
-- no rescanning).

-- ➊ Build large (10⁶ rows) tables left/right with unique join criteria
DROP TABLE IF EXISTS "left";
DROP TABLE IF EXISTS "right";

CREATE TABLE "left"  (a int, b text);
CREATE TABLE "right" (a int, b text);

INSERT INTO "left" (a,b)
  SELECT i, md5(i::text)
  FROM   generate_series(1, 1000000) AS i;

INSERT INTO "right" (a,b)
  SELECT i + 999000, md5(i::text)       -- ⚠ overlap of left.a and right.a of 1000 rows only
  FROM   generate_series(1, 1000000) AS i;


-- 10 rows of "left" in the left.a/right.a overlap:
TABLE "left"
ORDER BY a
OFFSET 999000
LIMIT 10;

-- 10 rows of "right" in the left.a/right.a overlap:
TABLE "right"
ORDER BY a
LIMIT 10;


CREATE UNIQUE INDEX left_a  ON "left"  USING btree (a);  -- the join columns ARE
CREATE UNIQUE INDEX right_a ON "right" USING btree (a);  -- indeed unique!

ANALYZE "left";
ANALYZE "right";


-- ➋ Equi-join of two large tables with unique join criteria
--   (note that the Index Scan on "right" only scans 1000 rows)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT l.b AS b1, r.b AS b2
  FROM   "left" AS l, "right" AS r
  WHERE  l.a = r.a;


-- ➌ Repeat equi-join, but now Merge Join disabled, default working memory
set enable_mergejoin = off;
show work_mem;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT l.b AS b1, r.b AS b2
  FROM   "left" AS l, "right" AS r
  WHERE  l.a = r.a;

-- Hash Join suffers if we reduce the available working memory
set work_mem = '64kB';

EXPLAIN (VERBOSE, ANALYZE)
  SELECT l.b AS b1, r.b AS b2
  FROM   "left" AS l, "right" AS r
  WHERE  l.a = r.a;


-- ➍ Repeat equi-join, re-enable Merge Join, leave working memory constrained (64kB)
reset enable_mergejoin;
show work_mem;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT l.b AS b1, r.b AS b2
  FROM   "left" AS l, "right" AS r
  WHERE  l.a = r.a;


reset work_mem;


-----------------------------------------------------------------------
-- Demonstrate the "jumping the gap" technique.  Recursive query
-- simulates the lock-step movement in "left" and "right".  Relies on
-- B⁺Tree index support on columns left.a, right.a.
--
--  ⚠️ Only works if columns left.a, right.a are unique (no support
--  for repeating groups).


-- ➊ Original scan-based Merge Join
EXPLAIN (ANALYZE)
  SELECT l.b AS b1, r.b AS b2
  FROM   "left" AS l, "right" AS r
  WHERE  l.a = r.a;


-- ➋ B⁺Tree-based gap jumping
EXPLAIN (ANALYZE)
  WITH RECURSIVE merge(l, r) AS (
    SELECT
      (SELECT l FROM "left"  AS l ORDER BY l.a LIMIT 1),
      (SELECT r FROM "right" AS r ORDER BY r.a LIMIT 1)
  UNION ALL
    SELECT
      CASE WHEN (m.l).a < (m.r).a THEN
             (SELECT l1 FROM "left" AS l1 WHERE l1.a >= (m.r).a ORDER BY l1.a LIMIT 1) -- let ← jump forward using the index
           WHEN (m.l).a = (m.r).a THEN
             (SELECT l1 FROM "left" AS l1 WHERE l1.a >  (m.r).a ORDER BY l1.a LIMIT 1) -- let ← jump forward using the index
           ELSE m.l
      END,
      CASE WHEN (m.r).a < (m.l).a THEN
             (SELECT r1 FROM "right" AS r1 WHERE r1.a >= (m.l).a ORDER BY r1.a LIMIT 1) -- let → jump forward using the index (never executed)
           WHEN (m.r).a = (m.l).a THEN
             (SELECT r1 FROM "right" AS r1 WHERE r1.a >  (m.l).a ORDER BY r1.a LIMIT 1) -- let → jump forward using the index
           ELSE m.r
      END
    FROM   merge AS m
    WHERE  m IS NOT NULL -- m.l and/or m.r may be NULL if there is no larger value to jump forward to
  )
SELECT (m.l).b AS b1, (m.r).b AS b2
FROM   merge AS m
WHERE  (m.l).a = (m.r).a;


-----------------------------------------------------------------------
-- QUIZ: Explain the following behavior (see "rows = 1" in Index Scan on "right")

EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT l.b AS b1, r.b AS b2
  FROM   "left" AS l, "right" AS r
  WHERE  l.a = r.a AND l.a < 1000;


-----------------------------------------------------------------------
-- Demonstrate Hash Join in PostgreSQL plans

-- ➊ Check input tables
\d one

\d many


-- ➋ Equi-join is performed via Hash Join (the smaller one table becomes the build table)
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT o.*, m.*
  FROM   one AS o, many AS m
  WHERE  o.a = m.a;


-- ➌ Requiring less columns from the build table (semi-join): can build more compact hash table
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT m.*
  FROM   one AS o, many AS m
  WHERE  o.a = m.a;


-- ➍ Reduce working memory: split build table in partitions, iterate build/probe phases
set work_mem = '64kB';

EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT m.*
  FROM   one AS o, many AS m
  WHERE  o.a = m.a;

reset work_mem;

-----------------------------------------------------------------------
-- Demonstrate the creation of batches during Hash Join when
-- the available working memory is decreased

-- ➊ Check the input tables and working memory
\d one

\d many

show work_mem;


-- ➋ Perform Hash Joins with decreasing memory
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.a = m.a;


-- PostgreSQL aims for a bucket length (rows per bucket) of ⩽ 10 to avoid
-- long intra-bucket searches.

set work_mem = '256kB';

EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.a = m.a;


set work_mem = '128kB';

EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT *
  FROM   one AS o, many AS m
  WHERE  o.a = m.a;


-- ➌ Create a variant of table many which is super-heavily skewed:
--   all rows in table many have a = 1.  Expect build/probe rows
--   with a = 1 to be placed in in-memory skew batch.  All probe
--   rows will hit the skew batch, no probe row will be place in
--   on-disk batches:

DROP TABLE IF EXISTS many1;
CREATE TABLE many1 AS
  SELECT 1 AS a, m.b, m.c
  FROM   many AS m;

ANALYZE many1;

-- Check column statistics (e.g., most common values) in skewed table
SELECT attname, n_distinct, null_frac, most_common_vals
FROM   pg_stats
WHERE  tablename = 'many1' AND attname IN ('a', 'c');

-- Repeat query Q11 over skewded table "many1"
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT *
  FROM   one AS o, many1 AS m
  WHERE  o.a = m.a;


reset work_mem;

-----------------------------------------------------------------------
