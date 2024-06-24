-- ⚠️ Talking SQL to MonetDB here (mclient -l sql)

-- ➊ Prepare table sorted (as on slides)
DROP TABLE IF EXISTS sorted;
CREATE TABLE sorted (a text, s int);

INSERT INTO sorted(a,s) VALUES
  ('a', 40),
  ('b',  0),
  ('c', 50),
  ('d', 30),
  ('e', 50),
  ('f', 10),
  ('g', 50),
  ('h', 10),
  ('i', 10),
  ('j', 20);


-- ➋ MAL plan for a sorting query (look for MAL operator algebra.sort)
EXPLAIN
  SELECT s.*
  FROM   sorted AS s
  ORDER BY s.s;


-- ➌ Repeated sorting of a table for a given sort criterion leads MonetDB
-- to create a persistent order index (start MonetDB server via
-- "mserver5 ... --algorithms" to log tactical optimizations)
SELECT s.*
FROM   sorted AS s
ORDER BY s.s;


-- ➍ Alternatively, explicitly create a persistent order index
ALTER TABLE sorted SET READ ONLY;
CREATE ORDERED INDEX oidx_s ON sorted(s);

-- EXPLAIN plan is unchanged: algebra.sort optimizes tactically
SELECT s.*
FROM   sorted AS s
ORDER BY s.s;


-- ➎ Multi-criteria ORDER BY leads to order index refinement
EXPLAIN
  SELECT s.a, s.s
  FROM   sorted AS s
  ORDER BY s.s, s.a;


-- ⚠️ Talking MAL to MonetDB below (mclient -l msql)

-- Readable and executable excerpt of the resulting MAL plan for ➎:

sql := sql.mvc();
sorted:bat[:oid] := sql.tid(sql, "sys", "sorted");
a0    :bat[:str] := sql.bind(sql, "sys", "sorted", "a", 0:int);
a     :bat[:str] := algebra.projection(sorted, a0);
# ➊ ... ORDER BY s.s
s0    :bat[:int] := sql.bind(sql, "sys", "sorted", "s", 0:int);
s     :bat[:int] := algebra.projection(sorted, s0);
(s_ord_s, oidx_s, gidx_s) := algebra.sort(s, false, false, false);
# ➋ refine ... ORDER BY s.s, s.a
(a_ord_sa, oidx_sa, gidx_sa) := algebra.sort(a, oidx_s, gidx_s, false, false, false); # 🠴
s_ord_sa:bat[:int] := algebra.projection(oidx_sa, s);
a_ord_sa:bat[:str] := algebra.projection(oidx_sa, a);

io.print(a_ord_sa, s_ord_sa);
