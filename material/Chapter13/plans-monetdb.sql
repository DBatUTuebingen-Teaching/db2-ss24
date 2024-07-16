-- Demonstrate the evaluation of complex MAL plans, follows a
-- leaf-to-root (bottom-up, post-order) traversal of the plan tree.
-- Display intermediate result BATs along the way.

-- ⚠️ Talking SQL to MonetDB here (mclient -l sql)

-- ➊ Prepare tables one, many
DROP TABLE IF EXISTS one;
DROP TABLE IF EXISTS many;

CREATE TABLE one  (a int PRIMARY KEY,
                   b text);
CREATE TABLE many (a int NOT NULL,
                   b text);

INSERT INTO one(a,b) VALUES
  (3, 'a'),
  (4, 'b'),
  (7, 'c'),
  (2, 'd'),
  (0, 'e'),
  (1, 'f'),
  (6, 'g'),
  (5, 'h');

INSERT INTO many(a,b) VALUES
  (5, 'H'),
  (5, 'H'),
  (3, 'A'),
  (2, 'D'),
  (0, 'E'),
  (2, 'D');


-- ➋ Algebraic query plan for Q₁₂ (PLAN)
PLAN
  SELECT o.a, COUNT(*) AS "#"
  FROM   one AS o, many AS m
  WHERE  o.a = m.a
  GROUP BY o.a
  ORDER BY o.a DESC;


-- ➌ MAL code for Q₁₂
-- (follows post-order traversal of above plan tree, column BATs one.b/many.b never accessed)
EXPLAIN
  SELECT o.a, COUNT(*) AS "#"
  FROM   one AS o, many AS m
  WHERE  o.a = m.a
  GROUP BY o.a
  ORDER BY o.a DESC;


-- ⚠️ Talking MAL to MonetDB below (mclient -l msql)

-- ➍ Readable and executable MAL code:
sql := sql.mvc();

#  Scan one.a
one    :bat[:oid] := sql.tid(sql, "sys", "one");
one_a0 :bat[:int] := sql.bind(sql, "sys", "one", "a", 0:int);
one_a  :bat[:int] := algebra.projection(one, one_a0);
io.print(one_a);

#  Scan many.a
many   :bat[:oid] := sql.tid(sql, "sys", "many");
many_a0:bat[:int] := sql.bind(sql, "sys", "many", "a", 0:int);
many_a :bat[:int] := algebra.projection(many, many_a0);
io.print(many_a);

#  (Hash) Equi-Join      no candidate lists ⬎        ⬎  no outer ⬎     ⬐ no result size estimate
(left, right) := algebra.join(one_a, many_a, nil:bat, nil:bat, false, nil:lng);
joined_one_a:bat[:int] := algebra.projection(left, one_a);
io.print(joined_one_a);

#  Group + Agg
(grouped_one_a, group_keys, group_sizes) := group.groupdone(joined_one_a);
keys_a:bat[:int] := algebra.projection(group_keys, joined_one_a);
count :bat[:lng] := aggr.subcount(grouped_one_a, grouped_one_a, group_keys, false);
#                  values to aggregate ⬏               ⬑ group IDs            ⬑ skip nils? [no: COUNT(*)]
io.print(keys_a, count);

#  Sort                                  ᵈᵉˢᶜ⬎     ⬐ⁿⁱˡ ˡᵃˢᵗ ⬐ˢᵗᵃᵇˡᵉ
(sorted_a, oidx, gidx) := algebra.sort(keys_a, true, true, false);
result_a    :bat[:int] := algebra.projection(oidx, keys_a);
result_count:bat[:lng] := algebra.projection(oidx, count);
io.print(result_a, result_count);


-----------------------------------------------------------------------
-- Demonstrate the fully materialized evaluation of query plans

-- ⚠️ Talking SQL to MonetDB here (mclient -l sql)


-- ➊ MonetDB: prepare input table

DROP TABLE IF EXISTS hundred;

CREATE TABLE hundred (i int);
INSERT INTO hundred(i)
  SELECT value
  FROM   generate_series(1, 101); -- 100 rows

\d hundred


-- Evaluate large cross-products (⚠ materialization)

\t clock

SELECT 42 AS fortytwo
FROM   hundred AS h1, hundred AS h2, hundred AS h3
LIMIT 1;

SELECT 42 AS fortytwo
FROM   hundred AS h1, hundred AS h2, hundred AS h3, hundred AS h4
LIMIT 1;

EXPLAIN
  SELECT 42 AS fortytwo
  FROM   hundred AS h1, hundred AS h2, hundred AS h3, hundred AS h4
  LIMIT 1;


-- ⚠️ Does NOT terminate in reasonable time, need to kill mclient and mserver5 (-9)
--     (huge virtual memory size [VSIZE], all PhysMem used, heavy swapping)
SELECT 42 AS fortytwo
FROM   hundred AS h1, hundred AS h2, hundred AS h3, hundred AS h4, hundred AS h5
LIMIT 1;

-- NB. Experiment [***] continues in plans.sql
