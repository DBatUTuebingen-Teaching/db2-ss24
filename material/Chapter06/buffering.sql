-- Check the size of RAM set aside to hold the PostgreSQL buffer:
show shared_buffers;

-- Enable a PostgreSQL extension that lets us peek inside the buffer:
CREATE EXTENSION IF NOT EXISTS pg_buffercache;

-- How many pages can the current buffer hold overall?
SELECT COUNT(*)
FROM   pg_buffercache;

-- ⚠️ Cannot set buffer size from the psql client. Instead edit
--    configuration file postgresql.conf and restart the server:

set shared_buffers="128KB"; -- ERROR:  parameter "shared_buffers" cannot be changed without restarting the server


-----------------------------------------------------------------------
-- ⚠️ Experiment with a loooong series of SQL queries below


-- Prepare a large variant of the ternary table to help demonstrate
-- the dynamic buffer behavior:
DROP TABLE IF EXISTS ternary_100k;
CREATE TABLE ternary_100k (a int NOT NULL, b text NOT NULL, c float);
INSERT INTO ternary_100k(a, b, c)
 SELECT i,
        md5(i::text),
        log(i)
 FROM   generate_series(1, 100000, 1) AS i;

CHECKPOINT;

-- ⚠️ NOW RESTART THE POSTGRESQL SERVER TO FLUSH THE BUFFER CACHE


-- Which heap file contains the pages of table ternary_100k and how
-- many blocks/pages does the heap file occupy?
SELECT c.relfilenode, c.relpages
FROM   pg_class AS c
WHERE  c.relname = 'ternary_100k';
-- Save relfilenode into psql variable :relfilenode (used below)
\gset

-- Check that the buffer cache currently holds no pages of
-- table ternary_100k:
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode;

-- Now scan pages of ternary_100k.  Expect buffer cache MISSES for
-- all pages:
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT t.*
  FROM   ternary_100k AS t;

-- Check buffer cache for pages of ternary_100k: all pages in, not dirty,
-- usagecount = 1:
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode;

-- Re-scan all pages of ternary_100k. Now we see buffer HITS for all pages:
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT t.*
  FROM   ternary_100k AS t;

-- Re-check buffer cache contents for pages of ternary_100k: all pages
-- in, not dirty, usagecount = 2:
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode;

-- Scan all pages of ternary_100k with a < 100: buffer cache HITS for
-- ALL pages (since no index/ordering on the table):
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT t.*
  FROM   ternary_100k AS t
  WHERE  t.a < 100;

-- Re-check buffer cache contents for pages of ternary_100k: all pages
-- in, not dirty, usagecount = 3:
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode;


-- Now update a row in ternary_100k.  START TRANSACTION such that we can
-- observe things while they are in progress.

START TRANSACTION;

-- Update row with a = 10: buffer cache hits for all pages, two pages dirty:
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  UPDATE ternary_100k
  SET    c = -1
  WHERE  a = 10;  -- affected row on block 0 of ternary_100


-- Re-check buffer cache contents for pages of ternary_100k: pages of
-- old and new row version are now dirty:
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode;


-- Check page contents of pages for old and new row version,
-- note the updated row slots:
SELECT t_ctid, lp, lp_off, lp_len, t_xmin, t_xmax,
       (t_infomask::bit(16)  & b'0010000000000000')::int::bool AS "updated row?",
       (t_infomask2::bit(16) & b'0100000000000000')::int::bool AS "has been HOT updated?"
FROM heap_page_items(get_raw_page('ternary_100k', 0)); -- page 0 holds old row version

SELECT t_ctid, lp, lp_off, lp_len, t_xmin, t_xmax,
       (t_infomask::bit(16)  & b'0010000000000000')::int::bool AS "updated row?",
       (t_infomask::bit(16)  & b'0000000100000000')::int::bool AS "updating TX committed?"
FROM heap_page_items(get_raw_page('ternary_100k', 934)); -- page 934 holds new row version


-- Now commit the UPDATE change
COMMIT;


-- Re-check buffer cache contents for pages of ternary_100k: all pages
-- in, usage_count of pages 0 and 934 higher:
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode; -- AND b.isdirty;


-- Scan all pages of ternary_100k: buffer cache hits for all pages,
-- but two pages dirty (Q: WHAT?! After a *read-only* SCAN!?):
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT t.*
  FROM   ternary_100k AS t;


-- Check buffer cache for pages of ternary_100k: pages of old row and new row version dirty
-- - page with old row version: old row version marked as available for VACUUM
-- - page with new row version: bit xmin_committed of new row version is set (≡ updating TX has now committed)
--
-- Answer to Q above: This row maintenance is "piggy-backed" on the Seq Scan plan operation.
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode AND b.isdirty;

-- Old version of row (on page 0) has now been marked available for VACUUM:
SELECT t_ctid, lp, lp_off, lp_len, t_xmin, t_xmax
FROM   heap_page_items(get_raw_page('ternary_100k', 0));

-- New row version (on page 934) has now been marked as committed:
SELECT t_ctid, lp, lp_off, lp_len, t_xmin, t_xmax,
       (t_infomask::bit(16)  & b'0000000100000000')::int::bool AS "updating TX committed?"
FROM   heap_page_items(get_raw_page('ternary_100k', 934));


-- After a forced CHECKPOINT, all buffers are synced with disk image
CHECKPOINT;

SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode AND b.isdirty;

-- Experiment ends here
-----------------------------------------------------------------------

-- Reduce buffer size to simulate that buffer space is a scarce resource
-- (see 'show data_directory' for location of the PostgreSQL configuration file):

-- Edit postgresql.conf:
--
--      [...]
--      shared_buffers = 1MB        # FIXME 🠴
--      #shared_buffers = 128MB     # min 128kB
--                # (change requires restart)
--      [...]

-- ⚠️ RESTART PostgreSQL SERVER TO FLUSH THE BUFFER CACHE

-- Check resulting buffer size (128 slots, too few to hold table ternary_100k):
show shared_buffers;

SELECT COUNT(*)
FROM   pg_buffercache;

-- Check size of table ternary_100k (yes, it will swamp the small buffer):
SELECT c.relfilenode, c.relpages
FROM   pg_class AS c
WHERE  c.relname = 'ternary_100k';
-- Save relfilenode into psql variable :relfilenode (used below)
\gset


-- Currently, no pages of ternary_100k are present in the buffer:
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode;


-- Perform sequential scan on ternary_100k (935 buffer misses):
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT *
  FROM   ternary_100k;

-- ⚠️ Run the next query IMMEDIATELY AFTER

-- Check buffer contents: only 16(!) pages have been used:
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode;

-- ⚠️ Run the next query IMMEDIATELY AFTER

-- ⇒ A new sequential scan will see 935-16 = 919 buffer misses:
EXPLAIN (VERBOSE, ANALYZE, BUFFERS)
  SELECT *
  FROM   ternary_100k;


-- Re-check for buffer contents: some pages may show a
-- usagecount of 0 (⇒ potential victims)
SELECT b.bufferid, b.relblocknumber, b.isdirty, b.usagecount
FROM   pg_buffercache AS b
WHERE  b.relfilenode = :relfilenode;


-- ⚠ RESET SHARED_BUFFERS IN CONFIG FILE TO ORIGINAL VALUE (128 MB).
--   RESTART PostgreSQL SERVER.

-----------------------------------------------------------------------
