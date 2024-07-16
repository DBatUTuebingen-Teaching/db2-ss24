-- ### ###   ##     # #
--  #  #  # #       # #
--  #  ###  #   ### ###
--  #  #    #       # #
--  #  #     ##     # #
--
-- NB. Some of the following sample queries assume a TPC-H database
--     instance with scale factor SF = 0.01.  See directory TPC-H/.

-- connect to TPC-H database
\c tpch

-- Demonstrate the impact of query optimization (force join reordering off) and
-- show a (simple) example of unnesting in the FROM clause.

-- ➊ Check input tables
\d lineitem

\d orders

\d customer


-- ➋ Evaluate Q₁₄, force join reordering/unnesting OFF
set join_collapse_limit = 1;
set from_collapse_limit = 1;

-- (a) Explicit join order via JOIN … ON (join_collapse_limit)
EXPLAIN (ANALYZE)
  SELECT l.l_partkey, l.l_quantity, l.l_extendedprice
  FROM   lineitem AS l JOIN orders AS o
           ON (l.l_orderkey = o.o_orderkey)
         JOIN customer AS c
           ON (o.o_custkey = c.c_custkey)
  WHERE  c.c_name = 'Customer#000000001';


-- (b) Prescribed join order via subquery nesting in the FROM clause (from_collapse_limit)
EXPLAIN (ANALYZE)
  SELECT lo.l_partkey, lo.l_quantity, lo.l_extendedprice
  FROM   (SELECT l.l_partkey, l.l_quantity, l.l_extendedprice, o.o_custkey
          FROM   lineitem AS l, orders AS o
          WHERE  l.l_orderkey = o.o_orderkey) AS lo,
         customer AS c
  WHERE  c.c_name = 'Customer#000000001'
    AND  lo.o_custkey = c.c_custkey;

-- Plan shape and cardinalities:
--
--            | 35
--            ⨝
--        1     60175
--         σ     ⨝
--         |      
--    1500 c   l   o 15000
--           60175


-- ➋ Re-evaluate Q₁₄, with join reordering/unnesting enabled
reset join_collapse_limit;
reset from_collapse_limit;


EXPLAIN (ANALYZE)
  SELECT l.l_partkey, l.l_quantity, l.l_extendedprice
  FROM   lineitem AS l JOIN orders AS o
           ON (l.l_orderkey = o.o_orderkey)
         JOIN customer AS c
           ON (o.o_custkey = c.c_custkey)
  WHERE  c.c_name = 'Customer#000000001';


-- Plan shape and cardinalities:
--               | 35
--               ⨝
--           9    
--            ⨝    |
--        1      |
--         σ    |  |
--         |    |  |
--    1500 c    o  l 60175
--           15000

EXPLAIN (ANALYZE)
  SELECT lo.l_partkey, lo.l_quantity, lo.l_extendedprice
  FROM   (SELECT l.l_partkey, l.l_quantity, l.l_extendedprice, o.o_custkey
          FROM   lineitem AS l, orders AS o
          WHERE  l.l_orderkey = o.o_orderkey) AS lo,
         customer AS c
  WHERE  c.c_name = 'Customer#000000001'
    AND  lo.o_custkey = c.c_custkey;

-----------------------------------------------------------------------
-- Demonstrate subquery unnesting for nesting in the ➊ FROM clause
-- and nesting in the ➋ WHERE clause

-- ➊ Nesting the FROM clause

-- Original nested query
EXPLAIN (COSTS false)
  SELECT c.c_name
  FROM   customer AS c,
        (SELECT n.n_nationkey, n.n_name
         FROM   nation AS n) AS t
  WHERE c.c_nationkey = t.n_nationkey
    AND strpos(c.c_address, t.n_name) > 0;

-- Manual unnesting leads to the identical plan
EXPLAIN (COSTS false)
  SELECT c.c_name
  FROM   customer AS c, nation AS n
  WHERE  c.c_nationkey = n.n_nationkey
  AND    strpos(c.c_address, n.n_name) > 0;


-- ➋ Nesting in the WHERE clause: IN ⇒ semijoin

EXPLAIN (COSTS false)
  SELECT o.o_orderkey
  FROM   orders AS o
  WHERE  o.o_custkey IN
    (SELECT c.c_custkey
     FROM   customer AS c
     WHERE  c.c_name = 'Customer#000000001');


-- Variant of ➋: do not compare with key c_custkey ⇒ optimizer uses Hash Semi Join
-- which ensures that each o is matched with at most one join partner
EXPLAIN (COSTS false)
  SELECT o.o_orderkey
  FROM   orders AS o
  WHERE  o.o_clerk IN
    (SELECT c.c_name
     FROM   customer AS c);

-- Temporarily switch off Hash (Semi) Join
set enable_hashjoin = off;

-- Variant ➋ now uses a Merge Semi Join
EXPLAIN (COSTS false)
  SELECT o.o_orderkey
  FROM   orders AS o
  WHERE  o.o_clerk IN
    (SELECT c.c_name
     FROM   customer AS c);

reset enable_hashjoin;


-----------------------------------------------------------------------
-- Join tree optimization based on Dynamic Programming

/*

Building the 𝑜𝑝𝑡[·] and pruning plans early leads to a compact
representation of the explored search space. Example for 𝑛 = 4, all ⟁ᵢ
base tables (i.e., access(⟁ᵢ) considers Seq Scan, Index Scan, Bitmap
Scan):

  opt[{⟁₁}] = prune(access(⟁₁)) ← 3 plans considered                 ⎫
  opt[{⟁₂}] = …                                                      ⎬  4 × 3 = 12 plans considered,
  opt[{⟁₃}] = …                                                      ⎮  only 4 plans memorized
  opt[{⟁₄}] = …                                                      ⎭


  opt[{⟁₁,⟁₂}] = prune(opt[{⟁₁}] ⊛ opt[{⟁₂}]) ← 6 plans considered   ⎫
  opt[{⟁₁,⟁₃}] = …                                                   ⎮
  opt[{⟁₁,⟁₄}] = …                                                   ⎬  6 × 6 = 36 plans considered,
  opt[{⟁₂,⟁₃}] = …                                                   ⎮  only 6 plans memorized
  opt[{⟁₂,⟁₄}] = …                                                   ⎮
  opt[{⟁₃,⟁₄}] = …                                                   ⎭


  opt[{⟁₁,⟁₂,⟁₃}] = opt[{⟁₁}] ⊛ opt[{⟁₂,⟁₃}] ∪ ⎫                     ⎫
                    opt[{⟁₂}] ⊛ opt[{⟁₁,⟁₃}] ∪ ⎬ 18 plans considered ⎮
                    opt[{⟁₃}] ⊛ opt[{⟁₁,⟁₂}]   ⎭                     ⎬  4 × 18 = 72 plans considered,
  opt[{⟁₁,⟁₃,⟁₄}] = …                                                ⎮  only 4 plans memorized
  opt[{⟁₁,⟁₂,⟁₄}] = …                                                ⎮
  opt[{⟁₂,⟁₃,⟁₄}] = …                                                ⎭


  opt[{⟁₁,⟁₂,⟁₃,⟁₄}] = opt[{⟁₁}]    ⊛ opt[{⟁₂,⟁₃,⟁₄}] ∪              ⎫
                       opt[{⟁₂}]    ⊛ opt[{⟁₁,⟁₃,⟁₄}] ∪              ⎮
                       opt[{⟁₃}]    ⊛ opt[{⟁₁,⟁₂,⟁₄}] ∪              ⎮
                       opt[{⟁₄}]    ⊛ opt[{⟁₁,⟁₂,⟁₃}] ∪              ⎬ 42 plans considered,
                       opt[{⟁₁,⟁₂}] ⊛ opt[{⟁₃,⟁₄}]    ∪              ⎮ only 1 plan memorized
                       opt[{⟁₁,⟁₃}] ⊛ opt[{⟁₂,⟁₄}]    ∪              ⎮
                       opt[{⟁₁,⟁₄}] ⊛ opt[{⟁₂,⟁₃}]                   ⎭

                                                                     Σ 162 plans considered
                                                                       15 plans memorized

*/


-----------------------------------------------------------------------
-- Demonstrate that the PostgreSQL space$-based cost model
-- does not try to estimate the true cost of plan evaluation


-- Table ternary is not part of TPC-H
\c scratch

-- ➊ Create input table
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (a int NOT NULL, b text NOT NULL, c float);

INSERT INTO ternary(a, b, c)
  SELECT i            AS a,
         md5(i::text) AS b,
         log(i)       AS c
  FROM   generate_series(1, 1000, 1) AS i;

-- ➋ Plan/evaluate two queries with same space$ cost but *wildly*
--   different true cost

EXPLAIN (VERBOSE, ANALYZE)
 SELECT t.a::bigint + 1    -- same data type as used by factorial(_)
 FROM   ternary AS t;


EXPLAIN (VERBOSE, ANALYZE)
 SELECT factorial(t.a)
 FROM   ternary AS t;


-----------------------------------------------------------------------
-- Demonstrate the cost derivation for Seq Scan on table "indexed"


-- ➊ Set up input table
DROP TABLE IF EXISTS indexed;
CREATE TABLE indexed (a int PRIMARY KEY, b text, c numeric(3,2));

INSERT INTO indexed(a,b,c)
  SELECT i, md5(i::text), sin(i)
  FROM   generate_series(1,1000000) AS i;

ALTER INDEX indexed_pkey RENAME TO indexed_a;
ANALYZE indexed;

\d indexed


-- ➋ Obtain meta data about table indexed
SELECT reltuples AS "#rows(indexed)", relpages AS "#pages(indexed)"
FROM   pg_class
WHERE  relname = 'indexed';


-- ➌ Simple Seq Scan (no filter)
EXPLAIN VERBOSE
  SELECT i.a
  FROM   indexed AS i;

/*

- startup_cost  = startup_cost(pred) + startup_cost(expr) = 0 + 0
                = 0.00 ✔︎

- cpu_run_cost  =   #rows(indexed) × (cpu_tuple_cost + run_cost(pred))
                  + #rows(indexed) × sel(pred) × run_cost(expr)
                =   10⁶ × (0.01 + 0)
                  + 10⁶ × 1.0 × 0
                = 10000.00

- disk_run_cost = #pages(indexed) × seq_page_cost
                = 9346 × 1.0
                = 9346.00

- total_cost    = startup_cost + cpu_run_cost + disk_run_cost
                = 0.00 + 10000.00 + 9346.00
                = 19346.00 ✔︎

*/


-- ➍ Simple Seq Scan (no filter but "complex" SELECT clause expr)
EXPLAIN VERBOSE
  SELECT i.a * 2 + 1
  FROM indexed AS i;

/*

- startup_cost  = startup_cost(pred) + startup_cost(expr) = 0 + 0
                = 0.00 ✔︎

- cpu_run_cost  =   #rows(indexed) × (cpu_tuple_cost + run_cost(pred))
                  + #rows(indexed) × sel(pred) × run_cost(expr)
                =   10⁶ × (0.01 + 0)
                  + 10⁶ × 1.0 × 2 × 0.0025
                = 15000.00        🠵
                                  run_cost(expr) = 2 × cpu_operator_cost: · * ·, · + ·

- disk_run_cost = #pages(indexed) × seq_page_cost
                = 9346 × 1.0
                = 9346.00

- total_cost    = startup_cost + cpu_run_cost + disk_run_cost
                = 0.00 + 15000.00 + 9346.00
                = 24346.00 ✔︎

*/


-- ➎ Simple Seq Scan (with filter and SELECT clause expression)

-- enforce Seq Scan
set enable_indexscan = off;
set enable_bitmapscan = off;

EXPLAIN VERBOSE
  SELECT i.a * 2 + 1
  FROM indexed AS i
  WHERE i.a <= 100000;

-- See Soulver file simple_Seq_Scan.slvr


-- ➏ Simple Seq Scan (with complex subquery filter)

EXPLAIN (VERBOSE, ANALYZE)
    SELECT i.a
    FROM indexed AS i
    WHERE i.a <= (SELECT AVG(i.a) FROM indexed AS i);

/*

- Complex predicate i.a <= (SELECT AVG(i.a) FROM indexed AS i):
  - startup_cost(i.a <= (SELECT AVG(i.a) FROM indexed AS i))
      = run_cost(SELECT AVG(i.a) FROM indexed AS i)
      = 21846.01
  - run_cost(i.a <= (SELECT AVG(i.a) FROM indexed AS i))
      = 2 × cpu_operator_cost 🠴 · :: numeric, · <= $0 ($0 is a constant once InitPlan 1 has been evaluated)
      = 2 × 0.0025
  - sel(i.a <= (SELECT AVG(i.a) FROM indexed AS i) = 333333 / 1000000 = 0.33 🠴 ⚠ arbitrary (1/3)
                                                                        (true selectivity: ≈ 1/2)


- startup_cost  = startup_cost(pred) + startup_cost(expr)
                = 21846.01 + 0
                = 21846.01 ✔︎

- cpu_run_cost  =   #rows(indexed) × (cpu_tuple_cost + run_cost(pred))
                  + #rows(indexed) × sel(pred) × run_cost(expr)
                =   10⁶ × (0.01 + 2 × 0.0025)
                  + 10⁶ × 0.33 × 0
                = 15000.0

- disk_run_cost = #pages(indexed) × seq_page_cost
                = 9346 × 1.0
                = 9346.00

- total_cost    = startup_cost + cpu_run_cost + disk_run_cost
                = 21846.01 + 15000.0 + 9346.00
                = 46192.01 ✔︎

*/

reset enable_indexscan;
reset enable_bitmapscan;


-----------------------------------------------------------------------
-- Demonstrate the cost derivation for Index Scan on table "indexed"

-- ➊ Prepare input table and indexes
CREATE INDEX indexed_c ON indexed USING btree (c);
CLUSTER indexed USING indexed_c;
ANALYZE indexed;

\d indexed


-- ➋ Obtain meta data about table indexed
SELECT relname, reltuples AS "#rows(･)", relpages AS "#pages(･)"
FROM   pg_class
WHERE  relname LIKE 'indexed%';


SELECT correlation AS "corr(indexed_a)"
FROM   pg_stats
WHERE  tablename = 'indexed' AND attname = 'a';


SELECT level AS "h(indexed_a)"
FROM   bt_metap('indexed_a');


-- ➌ Enforce an index range scan over a NON-CLUSTERED index
--   (cf. with Seq Scan query ➎ above which had significantly lower cost)
set enable_bitmapscan = off;
set enable_seqscan = off;

EXPLAIN VERBOSE
  SELECT i.c * 2 + 1
  FROM indexed AS i
  WHERE i.a <= 100000;

-- See Soulver file Index_Scan.slvr


-- ➍ Perform a index range scan over a CLUSTERED index
--   (cf. with Seq Scan query ➎ above which had significantly higher cost)
CLUSTER indexed USING indexed_a;
ANALYZE indexed;

SELECT correlation AS "corr(indexed_a)"
FROM   pg_stats
WHERE  tablename = 'indexed' AND attname = 'a';

EXPLAIN VERBOSE
  SELECT i.c * 2 + 1
  FROM indexed AS i
  WHERE i.a <= 100000;

-- See Soulver file Index_Scan.slvr


-- ➎ Perform index-ONLY scan over an index

-- make sure dead rows are removed (visibility map update)
VACUUM;

EXPLAIN VERBOSE
  SELECT i.a * 2 + 1         -- NB: accesses column "a" only
  FROM indexed AS i
  WHERE i.a <= 100000;

-- See Soulver file Index_Scan.slvr

reset enable_indexscan;
reset enable_bitmapscan;
