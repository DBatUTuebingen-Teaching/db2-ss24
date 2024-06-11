-- Create and populate playground table indexed.  This will also
-- automatically create an associated B⁺Tree index (named indexed_pkey,
-- but renamed to indexed_a below) that supports value-based access
-- via the primary key.
DROP TABLE IF EXISTS indexed;
CREATE TABLE indexed (
  a int PRIMARY KEY,
  b text,
  c numeric(3,2));

-- Updates table AND ALSO updates any index
INSERT INTO indexed(a,b,c)
  SELECT i, md5(i::text), sin(i)
  FROM   generate_series(1,1000000) AS i;

\d indexed

-- Rename index, only to follow our ‹table›_‹column› convention
ALTER INDEX indexed_pkey RENAME TO indexed_a;

\d indexed

-- The index is an additional data structure, maintained by the DBMS.
-- Lives persistently in extra heap file.
SELECT relname, relfilenode, relpages, reltuples, relkind
FROM   pg_class
WHERE  relname LIKE 'indexed%';

-----------------------------------------------------------------------
-- Performance impact of Index Scan is significant

-- Evaluate Q8 with index support enabled
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.b, i.c
  FROM   indexed AS i
  WHERE  i.a = 42;

-- ⚠️ Temporarily disable index support
set enable_indexscan = off;
set enable_bitmapscan = off;

-- Reevaluate Q8 without index support
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.b, i.c
  FROM   indexed AS i
  WHERE  i.a = 42;

-- Re-enable index support
set enable_indexscan = on;
set enable_bitmapscan = on;


-----------------------------------------------------------------------
-- Inspecting B⁺Tree leaf nodes using the pageinspect extension

-- Enable pageinspect extension
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- How many pages are there in indexed_a overall?
SELECT relname, relfilenode, relpages, reltuples, relkind
FROM   pg_class
WHERE  relname LIKE 'indexed%';

-- Switch to expanded (vertical) display of wide rows
\x on

-- Visit all index pages, dump only the leaf node pages (page 0 is special)
SELECT node.*
FROM   generate_series(1, 2744) AS p,
       LATERAL bt_page_stats('indexed_a', p) AS node
WHERE  node.type = 'l'  -- l ≡ leaf, i ≡ inner, r ≡ root
ORDER BY node.blkno
LIMIT 3;

-- Back to normal row display
\x off

-- Recursively walk the sequence set chain and extract the
-- number of index entries found in each leaf (subtract 1
-- from live_items for all pages but the rightmost page)
WITH RECURSIVE sequence_set(leaf, next, entries) AS (
  -- Find first (leftmost) node in sequence set
  SELECT node.blkno          AS leaf,
         node.btpo_next      AS next,
         node.live_items - (node.btpo_next <> 0)::int AS entries  -- node.btpo_next <> 0 ≡ node is not rightmost on tree level
  FROM   pg_class AS c,
         LATERAL generate_series(1, c.relpages-1) AS p,
         LATERAL bt_page_stats('indexed_a', p) AS node
  WHERE  c.relname = 'indexed_a' AND c.relkind = 'i'
  AND    node.type = 'l' AND node.btpo_prev = 0
   UNION ALL
  -- Find next (if any) node in sequence set
  SELECT node.blkno          AS leaf,
         node.btpo_next      AS next,
         node.live_items - (node.btpo_next <> 0)::int AS entries
  FROM   sequence_set AS s,
         LATERAL bt_page_stats('indexed_a', s.next) AS node
  WHERE  s.next <> 0
)
-- TABLE sequence_set;
SELECT SUM(s.entries) AS entries
FROM   sequence_set AS s;


-----------------------------------------------------------------------
-- Now focus on the leaf entries on page #1 of indexed_a:

-- Access leaf entries on page #1 (a leaf page, see above) of indexed_a:
SELECT *
FROM   bt_page_items('indexed_a', 1);


-- Follow RID (3,44) to check whether the row in table indexed carries
-- the expected key value 365 (= 0x016d):
SELECT *
FROM   indexed AS i WHERE i.ctid = '(3,44)';


-----------------------------------------------------------------------
-- Explore root node and inner nodes of index indexed_a for table
-- indexed.

-- Locate B⁺Tree root node
SELECT root, level
FROM   bt_metap('indexed_a');


-- Access B⁺Tree root node
\x on

SELECT *
FROM   bt_page_stats('indexed_a', 412);

\x off


-- Access index entries in root node (the root is rightmost on its level 2 and
-- thus has no high key)
SELECT itemoffset, itemlen, ctid, data
FROM   bt_page_items('indexed_a', 412)
ORDER BY itemoffset;

-- (Hint: can use the below to convert from hex to decimal using SQL)
SELECT x'019777'::int;


-- Explore B⁺Tree subtree with root page 411
-- (hosts index entries for values 104311 ⩽ a < 208621)
\x on

SELECT *
FROM bt_page_stats('indexed_a', 411);

\x off

-- Explore index entries in B⁺Tree inner node on page 411
-- (hosts index entries for values 104311 ⩽ 𝑎 < 208621),
-- 411 is non-rightmost on its level 1 and thus has a high key
-- (≡ smallest key value on next subtree on level 1)
SELECT itemoffset, itemlen, ctid, data
FROM   bt_page_items('indexed_a', 411)
ORDER BY itemoffset
LIMIT 10;


-- Explore leaf entries on B⁺Tree leaf node on page 288,
-- hosts index entries for values 104677 ⩽ a < 105043
-- (hex: 0x0198e5 ⩽ a < 0x019a53)
SELECT itemoffset, itemlen, ctid, data
FROM   bt_page_items('indexed_a', 288)
ORDER BY itemoffset;


-----------------------------------------------------------------------
-- PostgreSQL prefers Index Scan when the index
-- condition is selective and the cost of accessing the index AND
-- the heap file appears sufficiently low:

EXPLAIN ANALYZE
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.a < 1000;


EXPLAIN ANALYZE
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.a < 500000;


EXPLAIN ANALYZE
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.a < 700000;


-- Forcing PostgreSQL to use an index scan: there is indeed no benefit
-- for an Index Scan that accesses too many heap file pages:
set enable_seqscan = off;

EXPLAIN ANALYZE
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.a < 700000;

set enable_seqscan = on;

-----------------------------------------------------------------------
-- Indexes rock!  Thus create additional indexes on columns b and c:

CREATE INDEX indexed_b ON indexed USING btree (b text_pattern_ops);
CREATE INDEX indexed_c ON indexed USING btree (c);
\d indexed

CLUSTER indexed USING indexed_a;
-- Hey PostgreSQL, reconsider indexes and statistics for table indexed!
ANALYZE indexed;


-- Perform a selection column c (we expect an Index Scan on index indexed_c):
EXPLAIN ANALYZE
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.c = 0.42;

-- No Index Scan but Bitmap Index Scan + Bitmap Heap Scan?  What is going here?


-----------------------------------------------------------------------
-- Demonstrate the effect of clustering for the two indexes
-- indexed_a and indexed_c for two conditions of identical
-- selectivity.

-- Demonstrate two queries of identical complexity
EXPLAIN ANALYZE
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.a < 3532;         -- selection on a


EXPLAIN ANALYZE
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.c = 0.42;         -- selection on c


-- The 3531 matchings rows...
-- - indexed_a: ... cluster on fewer and closer heap file pages,
-- - indexed_c: ... are found on many pages spread all over the heap file.

-- Auxiliary function: extract page p from RID (p,_)
DROP FUNCTION IF EXISTS page_of(tid);
CREATE FUNCTION page_of(rid tid) RETURNS bigint AS
$$
  SELECT (rid::text::point)[0]::bigint;
$$
LANGUAGE SQL;


SELECT COUNT(DISTINCT page_of(i.ctid)) AS pages,
       MAX(page_of(i.ctid)) - MIN(page_of(i.ctid)) + 1 AS span
FROM   indexed AS i
WHERE  i.a < 3532;


SELECT COUNT(DISTINCT page_of(i.ctid)) AS pages,
       MAX(page_of(i.ctid)) - MIN(page_of(i.ctid)) + 1 AS span
FROM   indexed AS i
WHERE  i.c = 0.42;


-----------------------------------------------------------------------
-- Effect of tight working memory on Bitmap Index/Heap Scan,
-- switches from exact (row-level) to lossy (page-level) bitmap
-- encoding of matches.

show work_mem;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.c = 0.42;


-- Repeat query with severely restriced working memory
-- (enforce Bitmap Heap Scan):
set work_mem = '64kB';
set enable_indexscan = off;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.c = 0.42;

-- Back to normal configuration
reset work_mem;
reset enable_indexscan;

-----------------------------------------------------------------------
-- Demonstrate the effect of clustering on Bitmap Index Scan (find
-- all matches on significantly fewer pages).fewer

-- Perform Bitmap Index Scan on non-clustered index

EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.c = 0.42;


-- Recluster table 'indexed' based on index 'indexed_c', writes a new heap file
SELECT relfilenode
FROM   pg_class
WHERE  relname = 'indexed';

CLUSTER VERBOSE indexed USING indexed_c;

\d indexed

SELECT relfilenode
FROM   pg_class
WHERE  relname = 'indexed';

-- Physical order of rows in heap file now coincides with order in column 'c'
SELECT i.ctid, i.*
FROM   indexed AS i
ORDER BY i.c -- DESC
LIMIT 10;


-- Determine the clustering factor for columns c and a
-- (⚠️ homework assignment):
SELECT 100.0 * COUNT(*) FILTER (WHERE ordered) / COUNT(*) AS clustering_factor
FROM   (SELECT page_of(i.ctid) -
               LAG(page_of(i.ctid), 1, 0::bigint) OVER (ORDER BY i.c) IN (0,1) AS ordered
        FROM   indexed AS i) AS _;                              -- 🠵


SELECT 100.0 * COUNT(*) FILTER (WHERE ordered) / COUNT(*) AS clustering_factor
FROM   (SELECT page_of(i.ctid) -
               LAG(page_of(i.ctid), 1, 0::bigint) OVER (ORDER BY i.a) IN (0,1) AS ordered
        FROM   indexed AS i) AS _;                              -- 🠵


-- Repeat query (Bitmap Index Scan will now touch less blocks)
EXPLAIN (VERBOSE, ANALYZE)
  SELECT i.a, i.b
  FROM   indexed AS i
  WHERE  i.c = 0.42;


-- Run ANALYZE on table 'indexed', DBMS updates statistics on
-- row order, now chooses Index Scan over Bitmap Index Scan
ANALYZE indexed;

EXPLAIN (VERBOSE, ANALYZE)
 SELECT i.a, i.b
 FROM   indexed AS i
 WHERE  i.c = 0.42;
