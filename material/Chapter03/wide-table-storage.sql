-- Create a three-column (i.e., wide) table and populate it
-- with 1000 rows:
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (
  a int NOT NULL,
  b text NOT NULL,
  c float);

INSERT INTO ternary(a, b, c)
  SELECT i            AS a,
         md5(i::text) AS b,  -- MD5 hash: 32-character string
         log(i)       AS c
  FROM   generate_series(1, 1000, 1) AS i;


ANALYZE ternary;

-- Q2: Retrieve all rows (in arbirary oder) and all columns of table ternary
SELECT t.*
FROM   ternary AS t;

-- Equivalent to Q2
TABLE ternary;

-- Sequential scan delivers wider rows now, width: 45 bytes
-- (cf. sequential scan over table unary, width: 4 bytes):
EXPLAIN VERBOSE
  SELECT t.*
  FROM ternary AS t;

-----------------------------------------------------------------------
-- Inspecting the page header of a heap file page

-- Enable a PostgreSQL extension that enables us to peek inside the
-- pages of a heap file (page header, row pointers_):
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- All rows of ternary, together with their RID (RID ≡ (‹page›, ‹i›),
-- where ‹i› identifies the row's row/line pointer lpᵢ):
SELECT t.ctid, t.*
FROM   ternary AS t;

-- Check the page headers of heap file pages 0 (first page)
-- and 9 (last page of file):
SELECT *
FROM   page_header(get_raw_page('ternary', 0));

SELECT *
FROM   page_header(get_raw_page('ternary', 9));

-- Cross-checking our findings on the pages with free space management
-- information:
VACUUM ternary;
SELECT *
FROM   pg_freespace('ternary');

-- Inspect the row pointers (of heap file page 0):
SELECT lp, lp_off, lp_len, t_hoff, t_ctid, t_infomask :: bit(16), t_infomask2
FROM   heap_page_items(get_raw_page('ternary', 0));

-- Cross-check with in on-disk heap file for contents of the
-- third row (lp = 3) on page 0:
show data_directory;          -- locate in-filesystem representation of PostgreSQL's persistent files

SELECT db.oid                    -- identify directory of database 'scratch'
FROM   pg_database AS db
WHERE  db.datname = 'scratch';

SELECT c.relfilenode            -- identify heap file of table 'ternary'
FROM   pg_class AS c
WHERE  c.relname = 'ternary';

SELECT t.ctid, t.*
FROM   ternary AS t
LIMIT 3;
