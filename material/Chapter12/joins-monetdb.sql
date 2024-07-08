-- Demonstrate the evaluation of an equi-join.  Prepare SQL
-- input tables and inspect MAL plan

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

-- ➋ Probe query Q11
SELECT o.b AS b1, m.b AS b2
FROM   one AS o,
       many AS m
WHERE  o.a = m.a;

EXPLAIN
  SELECT o.b AS b1, m.b AS b2
  FROM   one AS o,
         many AS m
  WHERE  o.a = m.a;

-----------------------------------------------------------------------
-- ⚠️ Now talking MAL (mclient -l msql)

-- Excerpt of equi-join MAL plan

sql := sql.mvc();

one    :bat[:oid] := sql.tid(sql, "sys", "one");
one_a0 :bat[:int] := sql.bind(sql, "sys", "one", "a", 0:int);
one_a  :bat[:int] := algebra.projection(one, one_a0);

many   :bat[:oid] := sql.tid(sql, "sys", "many");
many_a0:bat[:int] := sql.bind(sql, "sys", "many", "a", 0:int);
many_a :bat[:int] := algebra.projection(many, many_a0);

# ➊ compute join index BATs for left/right input tables
#                             nil matches? (outer join semantics)      result size estimate
#                                                               ↓      ↓
(left,right) := algebra.join(one_a, many_a, nil:bat, nil:bat, false, nil:lng);
#                                            ↑        ↑
#                                          candidate BATs
io.print(left,right);

one_b0 :bat[:str] := sql.bind(sql, "sys", "one", "b", 0:int);
many_b0:bat[:str] := sql.bind(sql, "sys", "many", "b", 0:int);

# ➋ apply (visbility and) join index BATs to both required output columns
b1     :bat[:str] := algebra.projectionpath(left, one, one_b0);
b2     :bat[:str] := algebra.projectionpath(right, many, many_b0);
io.print(b1,b2);

