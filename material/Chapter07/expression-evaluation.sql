-- Create the ternary table and populate it:
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (a int NOT NULL, b text NOT NULL, c float);

INSERT INTO ternary(a, b, c)
  SELECT i            AS a,
         md5(i::text) AS b,
         log(i)       AS c
  FROM   generate_series(1, 1000, 1) AS i;

EXPLAIN VERBOSE
  SELECT t.a * 3 - t.a * 2    AS a,
         t.a - power(10, t.c) AS diff,
         ceil(t.c / log(2))   AS bits
  FROM   ternary AS t;



-----------------------------------------------------------------------
-- ⚠️ The experiment below requires operational JIT support in your
--    PostgreSQL server (version 11 or later required, server compiled
--    with option --with-llvm, and PostgreSQL's LLVM libraries present).


-- Create a larger version of the well-known ternary table.  Evaluating
-- expressions over all rows of this table will require substantial time.
--
DROP TABLE IF EXISTS ternary_10M;
CREATE TABLE ternary_10M (a int NOT NULL, b text NOT NULL, c float);

INSERT INTO ternary_10M(a, b, c)
  SELECT i            AS a,
         md5(i::text) AS b,
         log(i)       AS c
  FROM   generate_series(1, 10000000, 1) AS i;


-- ➊ Forced JIT compilation for a (too) cheap query
--

set jit = off;

EXPLAIN ANALYZE VERBOSE
  SELECT t.a * 3 - t.a * 2    AS a,
         t.a - power(10, t.c) AS diff,
         ceil(t.c / log(2))   AS bits
  FROM   ternary AS t;




set jit = on;                      -- back to the default
set jit_above_cost = 10;           -- ⚠️ ridiculously low, we risk costly investment into
set jit_optimize_above_cost = 10;  --    JIT compilation for queries that are cheap to execute w/o JIT

-- WITH JIT forced, JIT compilation makes for almost 100%(!) of the execution time
-- for the (cheap) query below.  Observing a ≈ 40 × slow down (evaluate multiple
-- times for stable timings).
EXPLAIN ANALYZE VERBOSE
  SELECT t.a * 3 - t.a * 2    AS a,
         t.a - power(10, t.c) AS diff,
         ceil(t.c / log(2))   AS bits
  FROM   ternary AS t;


-- ➋ JIT compilation for a more expensive query
--
set jit = off;                      -- JIT compilation is the default since PostgreSQL 12

EXPLAIN ANALYZE VERBOSE
  SELECT t.a * 3 - t.a * 2    AS a,
         t.a - power(10, t.c) AS diff,
         ceil(t.c / log(2))   AS bits
  FROM   ternary_10M AS t;

set jit = on;                         -- back to the default
set jit_above_cost = 10000;           -- ⚠️ tune these parameters to invoke JIT compilation only for long-runnig
set jit_optimize_above_cost = 10000;  --    (indeed due to expression evaluation? — ¯\_(ツ)_/¯ ) queries

-- JIT compilation now consumes ≈5% of the overall execution time.  Observing
-- a performance improvement of about 20% due to JIT compilation.
EXPLAIN ANALYZE VERBOSE
  SELECT t.a * 3 - t.a * 2    AS a,
         t.a - power(10, t.c) AS diff,
         ceil(t.c / log(2))   AS bits
  FROM   ternary_10M AS t;

-- Back to default JIT configuration
reset jit;
reset jit_above_cost;
reset jit_optimize_above_cost;
