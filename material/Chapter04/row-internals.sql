-- Create three-column table ternary and populate it with
-- 1000 rows.  NB: every 10th row carries a NULL value in
-- column c:
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (
  a int  NOT NULL,  -- 4-byte integer
  b text NOT NULL,  -- variable width
  c float);         -- 8-byte floating point

INSERT INTO ternary(a, b, c)
  SELECT i                                              AS a,
         md5(i::text)                                   AS b,
         CASE WHEN i % 10 = 0 THEN NULL ELSE log(i) END AS c  -- place NULL in every 10th row
  FROM   generate_series(1, 1000, 1) AS i;

TABLE ternary;

ANALYZE ternary;

-- Probe query Q3: Retrieve all rows (in arbirary order) but
-- retrieve columns a, c only (column b "projected away"):
SELECT t.a, t.c
FROM   ternary AS t;

-- Show plan for Q3:
EXPLAIN VERBOSE
  SELECT t.a, t.c
  FROM ternary AS t;

-----------------------------------------------------------------------
-- Check PostgreSQL's system catalog for the widths (attlen) of the
-- columns of table ternary and check for memory alignment
-- requirements (attalign):

SELECT a.attnum, a.attname, a.attlen, a.attstorage, a.attalign
FROM   pg_attribute AS a
WHERE  a.attrelid = 'ternary'::regclass AND a.attnum > 0
ORDER  BY a.attnum;

-----------------------------------------------------------------------
-- "Column Tetris"

-- Create and populate two tables that carry equivalent information.
-- Table packed arranges columns such that column values need NO PADDING
-- on the tables's heap file pages.  Do we see any benefit?  (You bet!)

DROP TABLE IF EXISTS padded;
DROP TABLE IF EXISTS packed;
CREATE TABLE padded (d int2, a int8, e int2, b int8, f int2, c int8);
CREATE TABLE packed (a int8, b int8, c int8, d int2, e int2, f int2);

INSERT INTO padded(d,a,e,b,f,c)
  SELECT 0,i,0,i,0,i
  FROM   generate_series(1,1000000) AS i;

INSERT INTO packed(a,b,c,d,e,f)
  SELECT i,i,i,0,0,0
  FROM generate_series(1,1000000) AS i;


-- Check how many pages are needed to store the rows of tables
-- padded and packed:
VACUUM padded;
VACUUM packed;

SELECT COUNT(*)
FROM   pg_freespace('padded');

SELECT COUNT(*)
FROM   pg_freespace('packed');

-- Check how many rows are found on each page of tables
-- padded and packed:
SELECT lp, lp_off, lp_len, t_hoff, t_ctid
FROM   heap_page_items(get_raw_page('padded',0));

SELECT lp, lp_off, lp_len, t_hoff, t_ctid
FROM   heap_page_items(get_raw_page('packed',0));

-- Can the query processor benefit (see cost output in plan)?
EXPLAIN VERBOSE
  SELECT p.*
  FROM   padded AS p;

EXPLAIN VERBOSE
  SELECT p.*
  FROM   packed AS p;

-----------------------------------------------------------------------
-- Representation of NULL in rows

-- Check the rows on page 0 of table ternary and how the row's meta
-- data represent NULL:
SELECT lp, lp_off, lp_len, t_hoff, t_ctid, t_infomask::bit(1) AS "any NULL?", t_bits
FROM heap_page_items(get_raw_page('ternary',0));

-- What's the representation of a row that entirely consists
-- of NULL values?
INSERT INTO padded(a,b,c,d,e,f)
  VALUES (NULL, NULL, NULL, NULL, NULL, NULL);

-- Which row is that all-NULL row? (Yield RID (‹p›,‹slot›))
SELECT p.ctid
FROM   padded AS p
WHERE  (p.a, p.b, p.c, p.d, p.e, p.f) IS NULL; -- ≡ a IS NULL AND b IS NULL AND ...

-- Take a closer look at that row:
SELECT lp, lp_off, lp_len, t_hoff, t_ctid, t_infomask::bit(1) AS "any NULL?", t_bits
FROM   heap_page_items(get_raw_page('padded', 0))   -- ⚠️ replace ‹p›
WHERE  lp = 108;                                      --    and ‹slot›

-----------------------------------------------------------------------
-- C routine slot_getattr(), excerpt of PostgreSQL source code file
-- src/backend/access/common/heaptuple.c:

/*
 * slot_getattr
 *    This function fetches an attribute of the slot's current tuple.
 *    It is functionally equivalent to heap_getattr, but fetches of
 *    multiple attributes of the same tuple will be optimized better,
 *    because we avoid O(N^2) behavior from multiple calls of
 *    nocachegetattr(), even when attcacheoff isn't usable.
 *
 *    A difference from raw heap_getattr is that attnums beyond the
 *    slot's tupdesc's last attribute will be considered NULL even
 *    when the physical tuple is longer than the tupdesc.
 */
Datum
slot_getattr(TupleTableSlot *slot, int attnum, bool *isnull)
{
  HeapTuple tuple = slot->tts_tuple;
  TupleDesc tupleDesc = slot->tts_tupleDescriptor;
  HeapTupleHeader tup;

  /*
   * system attributes are handled by heap_getsysattr
   */
  if (attnum <= 0)
  {
    if (tuple == NULL)    /* internal error */
      elog(ERROR, "cannot extract system attribute from virtual tuple");
    if (tuple == &(slot->tts_minhdr)) /* internal error */
      elog(ERROR, "cannot extract system attribute from minimal tuple");
    return heap_getsysattr(tuple, attnum, tupleDesc, isnull);
  }

  /*
   * fast path if desired attribute already cached
   */
  if (attnum <= slot->tts_nvalid)
  {
    *isnull = slot->tts_isnull[attnum - 1];
    return slot->tts_values[attnum - 1];
  }

  /*
   * return NULL if attnum is out of range according to the tupdesc
   */
  if (attnum > tupleDesc->natts)
  {
    *isnull = true;
    return (Datum) 0;
  }

  /*
   * otherwise we had better have a physical tuple (tts_nvalid should equal
   * natts in all virtual-tuple cases)
   */
  if (tuple == NULL)      /* internal error */
    elog(ERROR, "cannot extract attribute from empty tuple slot");

  /*
   * return NULL if attnum is out of range according to the tuple
   *
   * (We have to check this separately because of various inheritance and
   * table-alteration scenarios: the tuple could be either longer or shorter
   * than the tupdesc.)
   */
  tup = tuple->t_data;
  if (attnum > HeapTupleHeaderGetNatts(tup))
  {
    *isnull = true;
    return (Datum) 0;
  }

  /*
   * check if target attribute is null: no point in groveling through tuple
   */
  if (HeapTupleHasNulls(tuple) && att_isnull(attnum - 1, tup->t_bits))
  {
    *isnull = true;
    return (Datum) 0;
  }

  /*
   * If the attribute's column has been dropped, we force a NULL result.
   * This case should not happen in normal use, but it could happen if we
   * are executing a plan cached before the column was dropped.
   */
  if (TupleDescAttr(tupleDesc, attnum - 1)->attisdropped)
  {
    *isnull = true;
    return (Datum) 0;
  }

  /*
   * Extract the attribute, along with any preceding attributes.
   */
  slot_deform_tuple(slot, attnum);

  /*
   * The result is acquired from tts_values array.
   */
  *isnull = slot->tts_isnull[attnum - 1];
  return slot->tts_values[attnum - 1];
}

-----------------------------------------------------------------------
-- Experiment: how much time does PostgreSQL spent in routine
-- slot_deform_tuple() and slot_getattr() when a SQL query is
-- being processed?  (Spoiler: A LOT!)

-- Create and populate a larger version of table ternary (30M rows)
-- (⚠️ evaluation of the INSERT may take some time and disk space):
DROP TABLE IF EXISTS ternary_30M;
CREATE TABLE ternary_30M(
  a int  NOT NULL,
  b text NOT NULL,
  c float);

INSERT INTO ternary_30M(a, b, c)
  SELECT i                                             AS a,
        md5(i::text)                                   AS b,
        CASE WHEN i % 10 = 0 THEN NULL ELSE log(i) END AS c
  FROM   generate_series(1, 30000000, 1) AS i;

/*

A UNIX shell command to monitor all PostgreSQL DBMS kernel
processes and list their CPU activity:

eval (echo top -stats pid,command,cpu -pid (pgrep -d ' -pid ' -f postgres | sed 's/-pid $//'))

*/

-- How is time spent when PostgreSQL performs this query on the 30M table?
EXPLAIN (VERBOSE, ANALYZE)
  SELECT t.b, t.c
  FROM   ternary_30M AS t;

-----------------------------------------------------------------------
-- Final experiment: column projection takes time

-- If needed: re-create and populate the large ternary table of 10M rows
-- (⚠️ evaluation of the INSERT may take some time and disk space):
DROP TABLE IF EXISTS ternary_10M;
CREATE TABLE ternary_10M (
  a int  NOT NULL,
  b text NOT NULL,
  c float);

INSERT INTO ternary_10M(a, b, c)
  SELECT i                                             AS a,
        md5(i::text)                                   AS b,
        CASE WHEN i % 10 = 0 THEN NULL ELSE log(i) END AS c
  FROM   generate_series(1, 10000000, 1) AS i;

-- Does the evaluation time for an arbitrary projection (column order
-- c, b, a) differ from the retrieval in storage order (a, b, c)?
EXPLAIN (VERBOSE, ANALYZE)
  SELECT t.c, t.b, t.a
  FROM ternary_10M AS t;

EXPLAIN (VERBOSE, ANALYZE)
  SELECT t.*                -- also OK: t.a, t.b, t.c ≡ t.*,
  FROM ternary_10M AS t;    -- t.* is supported by a fast-path in PostgreSQL C code
