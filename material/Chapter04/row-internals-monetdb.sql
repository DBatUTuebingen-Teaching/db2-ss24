-- ⚠️ Talking SQL to MonetDB

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

SELECT t.*
FROM   ternary AS t
LIMIT 5;

-- Show the plan for probe query Q3 (NB: BAT for column b
-- is never read):
EXPLAIN
  SELECT t.a, t.c         -- column t.b NOT accessed
  FROM   ternary AS t;
