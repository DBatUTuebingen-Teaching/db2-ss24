
-- Create the ternary table and populate it:
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (a int NOT NULL, b text NOT NULL, c float);

INSERT INTO ternary(a, b, c)
  SELECT i            AS a,
         md5(i::text) AS b,
         log(i)       AS c
  FROM   generate_series(1, 1000, 1) AS i;

TABLE ternary;

-- Q4: Perform row insertions/updates/deletions (⚠️ no ANALYZE here, don't alter the table now):
EXPLAIN VERBOSE
 INSERT INTO ternary(a,b,c)
   SELECT t.a, 'Han Solo', t.c
   FROM   ternary AS t;

EXPLAIN VERBOSE
 UPDATE ternary AS t
   SET   c = -1
   WHERE t.a = 982;

EXPLAIN VERBOSE
  DELETE FROM ternary AS t
  WHERE  t.a = 982;

-----------------------------------------------------------------------

-- Recreate the ternary table and populate it.  This table will be
-- updated below:
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (a int NOT NULL, b text NOT NULL, c float);
INSERT INTO ternary(a, b, c)
    SELECT i            AS a,
           md5(i::text) AS b,
           log(i)       AS c
    FROM   generate_series(1, 1000, 1) AS i;


-- ➊ list rows on page 9 (table occupies 9 heap file pages)
SELECT t.ctid, t.*
FROM   ternary AS t
WHERE  t.ctid >= '(9,1)';

-- ➋ check row header contents before update
SELECT t_ctid, lp, lp_off, lp_len, t_xmin, t_xmax,
       (t_infomask::bit(16) & b'0010000000000000')::int::bool  AS "updated row?",
       (t_infomask2::bit(16) & b'0100000000000000')::int::bool AS "has been HOT updated?"
FROM heap_page_items(get_raw_page('ternary', 9));

-- ➌ check current transaction ID (≡ virtual timestamp)
SELECT txid_current();

SELECT txid_current();

-- ➍ update one row
UPDATE ternary AS t
SET    c = -1
WHERE  t.a = 982;

-- ➎ check visible contents of page 9 after update
SELECT t.ctid, t.*
FROM   ternary AS t
WHERE  t.ctid >= '(9,1)';

-- ➏ check row header contents after update
SELECT t_ctid, lp, lp_off, lp_len, t_xmin, t_xmax,
       (t_infomask::bit(16) & b'0010000000000000')::int::bool  AS "updated row?",
       (t_infomask2::bit(16) & b'0100000000000000')::int::bool AS "has been HOT updated?"
FROM heap_page_items(get_raw_page('ternary', 9));

-- check current transaction ID to double-check (non-)visibility of updated row
SELECT txid_current();

-----------------------------------------------------------------------
