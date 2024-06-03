-- Create the ternary table and populate it:
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (a int NOT NULL, b text NOT NULL, c float);

INSERT INTO ternary(a, b, c)
  SELECT i            AS a,
         md5(i::text) AS b,
         log(i)       AS c
  FROM   generate_series(1, 1000, 1) AS i;


-- Probe query Q7 (predicate evaluation):

EXPLAIN VERBOSE  -- also try: EXPLAIN ANALYZE
  SELECT t.a, t.b
  FROM   ternary AS t
  WHERE  t.a % 2 = 0 AND t.c < 1;


-----------------------------------------------------------------------
-- Heuristic predicate simplification

-- ➊ Remove double NOT() + De Morgan:

EXPLAIN VERBOSE
  SELECT t.a, t.b
  FROM   ternary AS t
  WHERE  NOT(NOT(NOT(t.a % 2 = 0 AND t.c < 1)));


-- ➋ Inverse distributivity of AND:

EXPLAIN VERBOSE
  SELECT t.a, t.b
  FROM   ternary AS t
  WHERE (t.a % 2 = 0 AND t.c < 1) OR (t.a % 2 = 0 AND t.c > 2);


-- Simulate query parameters as bound in a web form.  Predicate
-- simplification will rewrite the predicate into its minimal form,
-- avoiding evaluation overhead at query runtime.

-- parameter 'a' specified in web form
\set a NULL
-- parameter 'c' left unspecified (= wild card: any 'c' value is fine)
\set c NULL

EXPLAIN VERBOSE
  SELECT t.*
  FROM   ternary AS t
  WHERE  (t.a = :a OR :a IS NULL)
    AND  (t.c = :c OR :c IS NULL);

-----------------------------------------------------------------------

-- Create large variant of ternary table and populate it:
DROP TABLE IF EXISTS ternary_5M;
CREATE TABLE ternary_5M (a int NOT NULL, b text NOT NULL, c float);

INSERT INTO ternary_5M(a, b, c)
  SELECT i            AS a,
         md5(i::text) AS b,
         log(i)       AS c
  FROM   generate_series(1, 5000000, 1) AS i;


-- Order of clauses in a complex predicate (here: OR) can make a
-- difference if clause evaluation cost differs significantly.
-- Apparently, PostgreSQL has no clue about the predicate cost
-- (⚠️ This experiment is NOT about predicate selectivity.)

EXPLAIN ANALYZE
 SELECT *
 FROM ternary_5M AS t
 WHERE length(btrim(t.b, '0123456789')) < length(t.b)  -- costly clause
    OR t.a % 1000 <> 0;                                -- cheap clause


EXPLAIN ANALYZE
 SELECT *
 FROM   ternary_5M AS t
 WHERE  t.a % 1000 <> 0                                  -- cheap clause
    OR  length(btrim(t.b, '0123456789')) < length(t.b);  -- costly clause
