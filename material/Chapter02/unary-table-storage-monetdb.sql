-- ⚠️ Below we're talking SQL to MonetDB.  Start a MonetDB mclient session
--    with language flag '-l sql':

-- Create our playground table unary in MonetDB as usual:
DROP TABLE IF EXISTS unary;
CREATE TABLE unary (a int);

-- Populate the table with 100 integer rows (generate_series(s,e)
-- generates values less than e, default step delta is 1):
INSERT INTO unary(a)
  SELECT value
  FROM   generate_series(1, 101, 1);

-- Check table contents:
SELECT u.*
FROM   unary AS u;

-- MonetDB's plans for a SQL query are MonetDB Assembly Language (MAL)
-- programs:
EXPLAIN
  SELECT u.*
  FROM   unary AS u;

-----------------------------------------------------------------------

-- ⚠️ Below we're talking MAL (not SQL).  Start a MonetDB mclient session
--    with language flag '-l msql':

-- Create a new empty BAT and assign it to MAL variable t:
t := bat.new(nil:int);

-- Populate BAT t with integer values and check BAT contents (io.print):
bat.append(t, 42);
bat.append(t, 42);
bat.append(t, 0);
bat.append(t, -1);
bat.append(t, nil:int);
io.print(t);

-- BATs admit positional access to rows (fetch row at offset 3):
v := algebra.fetch(t, 3@0);
io.print(v);

-- Replace integer value in row at offset 4:
bat.replace(t, 4@0, 2);
io.print(t);

-- Extract positional slice from BAT (from offset 1 to 3).  The result
-- is a new BAT assigned to t1:
t1 := algebra.slice(t, 1@0, 3@0);
io.print(t1);

-- In t, offets (oids) are counted from 0, in t1 they are counted from 1:
b := bat.getSequenceBase(t);
io.print(b);
b := bat.getSequenceBase(t1);
io.print(b);

-- Deleting a row from a BAT leaves no holes (move last row in hole
-- left by deleted row):
bat.delete(t, 1@0);
io.print(t);

-----------------------------------------------------------------------

-- Use MAL to access the BAT (call it a) that holds the values in
-- column a of SQL table unary:
sql := sql.mvc();
a:bat[:int] := sql.bind(sql, "sys", "unary", "a", 0:int);
io.print(a);

-- Collect information about BAT a, in particular find out where its
-- persistent representation is found in the file system:
(i1,i2) := bat.info(a);
io.print(i1,i2);

-----------------------------------------------------------------------

-- ⚠️ Temporarily talk SQL again.  Start a MonetDB mclient session
--    with language flag '-l sql'.


-- Create a unary SQL table of string values.  The payload thus is
-- of variable width:
DROP TABLE IF EXISTS "unary'";
CREATE TABLE "unary'" (a text);

INSERT INTO "unary'"(a)
  SELECT s.w
  FROM   unary AS u, (VALUES (0, 'zero'),
                             (1, 'one'),
                             (2, 'two'),
                             (3, 'three'),
                             (4, 'four')) AS s(n, w)
  WHERE u.a % 5 = s.n;

SELECT u.*
FROM   "unary'" AS u;

-- ⚠️ Back to MAL.  Start a MonetDB mclient session
--    with language flag '-l msql'.

-- Access the BAT for column a of table unary.  Its details show
-- that *two* persistent files are used to represent the variable-width
-- payload:
-- (1) a tail file (see tail.filename) of offsets that point into ...
-- (2) ... a string dictionary file (see theap.filename).
sql := sql.mvc();
a:bat[:str] := sql.bind(sql, "sys", "unary'", "a", 0:int);
io.print(a);
(i1,i2) := bat.info(a);
io.print(i1,i2);
