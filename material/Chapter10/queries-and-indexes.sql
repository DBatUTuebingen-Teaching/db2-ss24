-- Recreate and populate playground table "indexed",
-- establish two B+Tree indexes on columns "a" and "c"
DROP TABLE IF EXISTS indexed;
CREATE TABLE indexed (a int PRIMARY KEY,
                      b text,
                      c numeric(3,2));
ALTER INDEX indexed_pkey RENAME TO indexed_a;
CREATE INDEX indexed_c ON indexed USING btree (c);

INSERT INTO indexed(a,b,c)
  SELECT i, md5(i::text), sin(i)
  FROM   generate_series(1,1000000) AS i;

ANALYZE indexed;

\d indexed

-- ➊ In the absence of an function-based index, this query
--   will be evaluated by a Seq Scan
EXPLAIN VERBOSE
  SELECT i.a
  FROM   indexed AS i
  WHERE  degrees(asin(i.c)) = 90;


-- NB:
-- degrees(x) = y ⇔ x = (y / 180.0) * π
-- asin(x)    = y ⇔ x = sin(y)

-- ➋ Retry the query with column i.c isolated:
EXPLAIN VERBOSE
  SELECT i.a
  FROM   indexed AS i
  WHERE  i.c = sin((90 / 180.0) * pi());


-- ➌ Another retry, now cast the compared value to the declared
--   type numeric(3,2) of column "c"
EXPLAIN VERBOSE
  SELECT i.a
  FROM   indexed AS i
  WHERE  i.c = sin((90 / 180.0) * pi()) :: numeric(3,2);


-- Is all of this worth it? Yes!

-- ➊ Will receive no index support (uses Seq Scan)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.a
  FROM   indexed AS i
  WHERE  degrees(asin(i.c)) = 90;

-- ➌ Receives index support (Bitmap Heap/Index Scan over indexed_c)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.a
  FROM   indexed AS i
  WHERE  i.c = sin((90 / 180.0) * pi()) :: numeric(3,2);

-----------------------------------------------------------------------
-- An expression-based index will match the original query ➊ above

--                                                expression over column "c"
--                                                             ↓
CREATE INDEX indexed_deg_asin_c ON indexed USING btree (degrees(asin(c)));
ANALYZE indexed;

\d indexed


-- ➊ The original query again
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.a
  FROM   indexed AS i
  WHERE  degrees(asin(i.c)) = 90;  -- matches indexed_deg_asin_c


-- Other useful expression-based indexes in practice:

-- CREATE INDEX ... USING btree (lower(lastname))
--
-- Supports queries like:
--
--   SELECT ...
--   FROM   ...
--   WHERE  lower(t.lastname) = lower('Kenobi')

-- CREATE INDEX ... USING btree (firstname || ' ' || lastname)

-----------------------------------------------------------------------
-- Expression-based indexes must be defined over deterministic
-- expressions (whose value at index creation time and query
-- time are always equal):

DROP FUNCTION IF EXISTS get_age(date);
CREATE FUNCTION get_age(d_o_b date) RETURNS int AS
$$
  SELECT extract(years from age(now(), d_o_b)) :: int
$$
LANGUAGE SQL;

DROP TABLE IF EXISTS people;
CREATE TABLE people (name text, birthdate date);
CREATE INDEX people_age ON people
  USING btree (get_age(birthdate));  -- ⚠️ illegal



-----------------------------------------------------------------------
-- PostgreSQL uses/ignores a composite index based
-- on how a filter predicate matches the index order

-- Clean-up indexes on tabled "indexed"
DROP INDEX indexed_c;
DROP INDEX indexed_deg_asin_c;

\d indexed

-- ➊ Even clean-up the primary key index on column "a",
--   then build a composite (c,a) B+Tree index
ALTER TABLE indexed DROP CONSTRAINT indexed_a;
CREATE INDEX indexed_c_a ON indexed USING btree (c,a);
ANALYZE indexed;

\d indexed

-- Check table and index size (# of heap pages):
SELECT relname, relkind, relpages
FROM   pg_class WHERE relname LIKE 'indexed%';


-- ➋ Visualize index entry order in index indexed_c_a:
SELECT i.c, i.a
FROM   indexed AS i
ORDER BY i.c, i.a
LIMIT  20
OFFSET 31840;


-- ➌ Evaluate query with predicate matching the (c,a) index:
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.*
  FROM   indexed AS i
  WHERE  i.c = 0.42;   -- 🠴 (c) is a prefix of (c,a)


-- ➍ Evaluate query with predicate NOT matching the (c,a) index:
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.*
  FROM   indexed AS i
  WHERE  i.a = 42;   -- 🠴 (a) not a prefix of (c,a)


-- ➎ Force PostgreSQL to use the (c,a) index despite the non-matching
--   predicate: will touch (almost) all pages of the index.
set enable_seqscan = off;
set enable_indexscan = off;


EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.*
  FROM   indexed AS i
  WHERE  i.a = 42;   -- 🠴 (a) not a prefix of (c,a)


reset enable_seqscan;
reset enable_indexscan;

-----------------------------------------------------------------------
-- Supporting predicates over multiple columns with a composite
-- index.

-- ➊ Table "indexed" now has composite (c,a) and (a,c) indexes
CREATE INDEX indexed_a_c ON indexed USING btree(a,c);
ANALYZE indexed;

\d indexed

-- Parameter m controls the selectivity of predicate p2
\set m 18000

-- ➋ Modify parameter m to render p2 more and more selective such that
--   PostgreSQL switches from using index (c,a) to (a,c).  Can perform
--   binary search regarding m to find switch point.

EXPLAIN
  SELECT i.b
  FROM   indexed AS i
  WHERE  i.c BETWEEN 0.00 AND 0.01  -- p1 more selective
    AND  i.a BETWEEN 0 AND :m;      -- p2 with m = 20000 less selective


-----------------------------------------------------------------------
-- Using low(!)-selectivity key prefixes in a B+Tree to implement
-- fast bulk inserts of data partitions and controlled merging of
-- partitions
--
-- See Goetz Graefe (2003), "Partitioned B-trees - a user's guide"
-- https://pdfs.semanticscholar.org/78ce/cd5f738c26ddefb3633f8a50bd6397ebc8dc.pdf

-- ➊ Create table of partitions, main/default partition is #0
DROP TABLE IF EXISTS parts;
CREATE TABLE parts (a int, b text, c numeric(3,2));

ALTER TABLE parts
  ADD COLUMN p int NOT NULL CHECK (p >= 0) DEFAULT 0;

INSERT INTO parts(a,b,c)
  SELECT i, md5(i::text), sin(i)
  FROM   generate_series(1,1000000) AS i;

CREATE INDEX parts_p_a ON parts USING btree (p, a);
CLUSTER parts USING parts_p_a;
ANALYZE parts;

\d parts

-- ➋ Bulk insert of a new partition #1 of data (uses B+Tree fast bulk loading)
INSERT INTO parts(p,a,b,c)
  --     🠷
  SELECT 1, random() * 1000000, md5(i::text), sin(i)
  FROM   generate_series(1,100000) AS i;


-- ➌ Bulk insert of a new partition #2 of data (uses B+Tree fast bulk loading
INSERT INTO parts(p,a,b,c)
  --     🠷
  SELECT 2, random() * 1000000, md5(i::text), sin(i)
  FROM   generate_series(1,100000) AS i;


-- ➍ Predicates that refer to column "a" will still be evaluated
--   using the "parts_p_a" index.  Rows participating in the query
--   (e.g., all rows/only recent rows/...) can be selected on a
--   by-partition basis.
--
--   (For an explanation of the BitmapOr operator you will find in
--    the plan, check DB2 Video #53.)
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT MAX(p.c)
  FROM   parts AS p
  WHERE  (p.p = 0 OR p.p = 1) AND p.a BETWEEN 0 AND 42;
  --     └──────────────────┘     └──────────────────┘
  --      select partition(s)      original predicate


-- ➎ Merge partition #1, #2 into main partition
UPDATE parts AS p
SET    p = 0 -- 🠴 merge partition 1 into main partition 0
WHERE  p.p = 1;

UPDATE parts AS p
SET    p = 0 -- 🠴 merge partition 2 into main partition 0
WHERE  p.p = 2;


-----------------------------------------------------------------------
-- Evaluate disjunctive predicates on multiple columns using
-- multiple separate indexes.

-- ➊ Prepare separate indexes on columns "a" and "c"
DROP INDEX IF EXISTS indexed_a_c;
DROP INDEX IF EXISTS indexed_c_a;

CREATE INDEX indexed_a ON indexed USING btree (a);
CREATE INDEX indexed_c ON indexed USING btree (c);
ANALYZE indexed;

\d indexed


-- ➋ Perform query featuring a disjunctive predicate
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.b
  FROM   indexed AS i
  WHERE  i.c BETWEEN 0.00 AND 0.01
     OR  i.a BETWEEN 0 AND 4000;


-- (See ➍ in the discussion of Partitioned B+Trees above for another
--  query example that employs BitmapOr.)


-- ➌ BitmapOr + two Bitmap Index Scans indeed pays off
set enable_bitmapscan = off;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.b
  FROM   indexed AS i
  WHERE  i.c BETWEEN 0.00 AND 0.01
     OR  i.a BETWEEN 0 AND 4000;

reset enable_bitmapscan;


-----------------------------------------------------------------------
-- String patterns (`LIKE`) influence predicate
-- selectivity and the resulting (index) scans chosen by PostgreSQL.

-- Create index on column "b" of table "indexed" that supports
-- pattern matching via LIKE
CREATE INDEX indexed_b ON indexed USING btree (b text_pattern_ops);
ANALYZE indexed;

\d indexed

-- Recall the contents of column "b"
SELECT i.b
FROM   indexed AS i
ORDER BY i.b
LIMIT  10;

-- ➊ Leading % wildcard: low selectivity
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.b LIKE '%42';


-- ➋ Leading character: medium selectivity
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.b LIKE 'a%42';


-- ➌ Leading characters: selectivity increases with length of
--   character sequence
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.b LIKE 'abc%42';


-----------------------------------------------------------------------
-- Cconstruction and matching of a *partial* index on
-- table "indexed".

-- ➊ Create partial index: a row is "hot" if its c value exceeds 0.5
CREATE INDEX indexed_partial_a ON indexed USING btree (a)
  WHERE c >= 0.5;
ANALYZE indexed;

\d indexed;


-- ➋ Check: the partial index is indeed smaller than the regular/full indexes
SELECT relname, relkind, relpages
FROM   pg_class
WHERE  relname LIKE 'indexed%';

SELECT (100.0 * COUNT(*) FILTER (WHERE i.c >= 0.5) / COUNT(*))::numeric(4,2) AS "% of hot rows",
       (100.0 * 922                                / 2745)    ::numeric(4,2) AS "% of index size"
FROM indexed AS i;


-- ➌ Do these queries match the partial index?  Check the resulting
--   "Index Cond" and "Filter" predicates in the EXPLAIN outputs.
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.a
  FROM   indexed AS i
  WHERE  c >= 0.6 AND a < 1000;


EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.a
  FROM   indexed AS i
  WHERE  c >= 0.5 AND a < 1000;


EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT i.a
  FROM   indexed AS i
  WHERE  c >= 0.4 AND a < 1000;


-----------------------------------------------------------------------
-- Demonstrate index-only query evaluation over table "indexed"
-- and its interplay with the table's visibility map.

-- Create a clean slate.
DROP TABLE IF EXISTS indexed;
CREATE TABLE indexed (a int PRIMARY KEY,
                      b text,
                      c numeric(3,2));
ALTER INDEX indexed_pkey RENAME TO indexed_a;

INSERT INTO indexed(a,b,c)
        SELECT i, md5(i::text), sin(i)
        FROM   generate_series(1,1000000) AS i;


-- ➊ Prepare (a,c) index.  Make sure that all rows on all
--   pages are indeed visible (VACCUM).
CREATE INDEX indexed_a_c ON indexed USING btree (a,c);
ANALYZE indexed;
VACUUM indexed;

\d indexed


-- ➋ Use extension pg_visibility to check the visibility map
--   (table indexed has 9346 pages)
CREATE EXTENSION IF NOT EXISTS pg_visibility;

SELECT blkno, all_visible
FROM   pg_visibility('indexed')
--
ORDER BY random()   -- pick a few random rows from the visibility map
LIMIT 10;           -- (all entries will have all_visible = true)


SELECT all_visible
FROM   pg_visibility_map_summary('indexed');


-- ➌ Perform sample index-only query
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT SUM(i.c) AS s
  FROM   indexed AS i
  WHERE  i.a < 10000;

set enable_indexonlyscan = off;

EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT SUM(i.c) AS s
  FROM   indexed AS i
  WHERE  i.a < 10000;

reset enable_indexonlyscan;


-- ➍ Table updates create old row version that are invisible
--   and may not be produced by an index-only scan
UPDATE indexed AS i
SET    b = '!'
WHERE  i.a % 150 = 0;  -- updates 6666 rows

SELECT all_visible
FROM   pg_visibility_map_summary('indexed');

-- This is the index-only query again but it will now touch lots of
-- heap file pages of table "indexed" to check for row visibility... :-/
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT SUM(i.c) AS s
  FROM   indexed AS i
  WHERE  i.a < 10000;


-- ➎ Touch even more rows, requiring even more heap-based visibility checks
--   ⇒ index-only scan becomes unattractive

UPDATE indexed AS i
SET    b = '!'
WHERE  i.a % 10 = 0;  -- updates 100000 rows, EVERY page is affected

SELECT all_visible
FROM   pg_visibility_map_summary('indexed');

-- This is the index-only query again.  The high number of needed row
-- visbility checks make Index Only Scan unattractive, however.
EXPLAIN (VERBOSE, ANALYZE)
  SELECT SUM(i.c) AS s
  FROM   indexed AS i
  WHERE  i.a < 10000;


-- ➏ Perform VACUUM to identify invisible rows and mark their
--   space ready for re-use (does not reclaim space and return it
--   to the OS yet), all remaining rows are visible
VACUUM indexed;

SELECT all_visible
FROM   pg_visibility_map_summary('indexed');

-- After VACUMM and index maintentance, a perfect Index Only Scan with
-- no heap fetches for row visbility checks returns. :-)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT SUM(i.c) AS s
  FROM   indexed AS i
  WHERE  i.a < 10000;


-----------------------------------------------------------------------
-- Demonstrate the index-only evaluation of MIN(i.c)/MAX(i.c)
-- and the enforcement of the SQL NULL semantics.

-- ➊ Prepare table and the index, the only index will the composite
--   (c,a) index
DROP TABLE IF EXISTS indexed;
CREATE TABLE indexed (a int PRIMARY KEY,
                      b text,
                      c numeric(3,2));

INSERT INTO indexed(a,b,c)
        SELECT i, md5(i::text), sin(i)
        FROM   generate_series(1,1000000) AS i;

ALTER TABLE indexed DROP CONSTRAINT indexed_pkey;
CREATE INDEX indexed_c_a ON indexed USING btree (c,a);
ANALYZE indexed;
VACUUM indexed;

\d indexed


-- ➋ Index-only evaluation of MIN(i.c)/MAX(i.c), look out for the
--   Index Only Scan *Backward*
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT MIN(i.c) AS m
  FROM   indexed AS i;


EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT MAX(i.c) AS m
  FROM   indexed AS i;

-----------------------------------------------------------------------
--  Demonstrate (non-)support of ORDER BY by Index Scan [Backward]:

-- ➊ supported (also show the value of pipelined "sort")
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c;

set enable_indexscan = off;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c;

reset enable_indexscan;


-- ➋ supported
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c DESC;


-- ➌ supported
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c, i.a;


-- ➍ supported
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c DESC, i.a DESC;


-- ➎ not supported
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c ASC, i.a DESC;  -- 🠴 does not match row visit order in scan


-- ➏ supported (also shows how Limit cuts off the Index Scan early → Volcano-style pipelining)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.c
  LIMIT 42;


-- ➐ not supported
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  ORDER BY i.a;


-- ➑ not really supported but could be supported just fine (supports predicate but not the ORDER BY clause)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  WHERE  i.c = 0.0
  ORDER BY i.a;

-- Force PostgreSQL to be reasonable...
set enable_bitmapscan = off;  -- 🠴 force the system into using Index Scan (to produce rows in a-sorted order)

-- ... now indeed uses Index Scan
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.*
  FROM   indexed AS i
  WHERE  i.c = 0.0
  ORDER BY i.a;

reset enable_bitmapscan;

-----------------------------------------------------------------------
-- Efficiently paging through a table

\set rows_per_page 10

-- Set up connections table and its index
DROP TABLE IF EXISTS connections;
CREATE TABLE connections (
  id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  "when"      timestamp,
  destination text
);

INSERT INTO connections ("when", destination)
  SELECT now() + make_interval(mins => i) AS "when",
         md5(i :: text) AS destination
  FROM   generate_series(1, 10000) AS i;

CREATE INDEX connections_when_id
  ON connections USING btree ("when", id);
ANALYZE connections;

\d connections

TABLE connections
ORDER BY "when", id
LIMIT 10;

-- Paging implementation option ➊: Using OFFSET and LIMIT

-- Browse pages, starting from #0
\set page 0

EXPLAIN (VERBOSE, ANALYZE)
  SELECT c.*
  FROM   connections AS c
  ORDER BY c."when"
  OFFSET :page * :rows_per_page
  LIMIT  :rows_per_page;

-- Continue browsing, at page #900 (of 10 rows each) now
\set page 900

EXPLAIN (VERBOSE, ANALYZE)
  SELECT c.*
  FROM   connections AS c
  ORDER BY c."when"
  OFFSET :page * :rows_per_page
  LIMIT  :rows_per_page;




-- Paging implementation option ➋: Using WHERE and LIMIT (NO OFFSET!)

-- Initialization: first connection is where we start browsing (page #0),
-- set :last_when, :last_id to that first connection
SELECT c."when", c.id
FROM   connections AS c
ORDER BY c."when", c.id
LIMIT 1;

--  sets :last_when, :last_id
\gset last_

SELECT :'last_when', :last_id;

-- Query submitted by the Web app: produce one page of connections
EXPLAIN (VERBOSE, ANALYZE)
  SELECT c.*
  FROM   connections AS c
  WHERE  (c."when", c.id) >= (:'last_when', :last_id)
  ORDER BY c."when", c.id  --  🠴 ORDER BY spec matches index scan order
  LIMIT  :rows_per_page;


-- Now pick a late connection (almost) at the end of the connection
-- table, again set :last_when, :last_id to that first connection.
SELECT c."when", c.id
FROM   (SELECT c.*
        FROM   connections AS c
        ORDER BY c."when" DESC, c.id DESC
        LIMIT :rows_per_page) AS c
ORDER BY c."when", c.id
LIMIT 1;

--  sets :last_when, :last_id
\gset last_


-- Query submitted by the Web app: produce one page of connections
EXPLAIN (VERBOSE, ANALYZE)
  SELECT c.*
  FROM   connections AS c
  WHERE  (c."when", c.id) >= (:'last_when', :last_id)
  ORDER BY c."when", c.id  --  🠴 ORDER BY spec matches index scan order
  LIMIT  :rows_per_page;
