-- ⚠️ Talking SQL to MonetDB (-l sql)

-- Create and populate three-column table ternary
-- with 1000 rows:
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (
  a int  NOT NULL,
  b text NOT NULL,
  c float);

INSERT INTO ternary(a, b, c)
  SELECT value        AS a,
         md5(value)   AS b,
         log10(value) AS c
  FROM   generate_series(1, 1001);


-- Look at the MAL plan for query Q7 (disjunctive predicate):
EXPLAIN
  SELECT t.a, t.b
  FROM   ternary AS t
  WHERE  t.a % 2 = 0 OR t.c < 1;


-----------------------------------------------------------------------
-- ⚠️ Talking MAL to MonetDB (-l msql)

-- Replay the evaluation of a q

sql := sql.mvc();
ternary:bat[:oid] := sql.tid(sql, "sys", "ternary");
a0     :bat[:int] := sql.bind(sql, "sys", "ternary", "a", 0:int);
a      :bat[:int] := algebra.projection(ternary, a0);
e1     :bat[:int] := batcalc.%(a, 2:int, ternary);   # 🠴 a % 2
io.print(e1);

# p1: selection vector (500 entries)
p1     :bat[:oid] := algebra.thetaselect(e1, 0:int, "==");  # 🠴 𝑝₁ ≡ a % 2 = 0
io.print(p1);

# p2: selection vector (9 entries)
c0     :bat[:dbl] := sql.bind(sql, "sys", "ternary", "c", 0:int);
c      :bat[:dbl] := algebra.projection(ternary, c0);
p2     :bat[:oid] := algebra.thetaselect(c, 1:dbl, "<");   # 🠴 𝑝₂ ≡ c < 1
io.print(p2);

# -------------------------------------------------------------------
# Interlude on range selection
#
#                  v </⩽ hi (false ≡ <)    complement result?
#                                     🠷       🠷
# algebra.select(col, lo, hi, true, false, false):
#                               🠵
#             lo </⩽ v (true ≡ ⩽)
#
#
# Return oids of values v in col in the range [lo, hi)

sv := algebra.select(c, 2:dbl, 2.1:dbl, true, false, false);  # 🠴 2 ⩽ c < 2.1
io.print(sv);

range := algebra.projection(sv, c);
io.print(range);

# End interlude on range selection
# -------------------------------------------------------------------

# or: selection vector (represents result of disjunction, 505 entries)
or := bat.mergecand(p1, p2);        #  🠴 𝑝₁ ∨ 𝑝₂
io.print(or);


# result construction (columns a, b; 505 resulting rows)
b0     :bat[:str] := sql.bind(sql, "sys", "ternary", "b", 0:int);
bres   :bat[:str] := algebra.projectionpath(or, ternary, b0);  # 🠴 applies visibility in ternary AND THEN selection vector
ares   :bat[:int] := algebra.projection(or, a);                # 🠴 applies selection vector
io.print(ares, bres);

-----------------------------------------------------------------------
