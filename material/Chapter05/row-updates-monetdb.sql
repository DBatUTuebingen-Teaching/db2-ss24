-- ⚠️ Talking SQL to MonetDB (mclient ... -lsql)

-- Recreate the ternary(a,b,c) playground table and populate it:
DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (a int NOT NULL, b text NOT NULL, c double);

INSERT INTO ternary(a, b, c)
  SELECT value, md5(value), log10(value)
  FROM   generate_series(1, 1001);

SELECT t.*
FROM   ternary AS t
LIMIT  5;

-- Disable auto commit (⇒ updated/inserted rows are held in
-- user-/transaction-local delta tables and the original BAT for
-- column c is NOT altered yet; the visibility of the changes is
-- thus limited to the current user or transaction):
\a

-- The following SQL DML commands will
--  - modify the visiblity BAT for column c (DELETE)
--  - store updated/inserted rows into the delta BATs
--    for column c (UPDATE/INSERT)
-- but will NOT change the BAT for column c yet:
EXPLAIN
  DELETE FROM ternary
  WHERE  a = 981;

DELETE FROM ternary
WHERE  a = 981;


EXPLAIN
  INSERT INTO ternary(a,b,c) VALUES
    (1001, 'Han Solo', -2);

INSERT INTO ternary(a,b,c) VALUES
  (1001, 'Han Solo', -2);


EXPLAIN
  UPDATE ternary
  SET    c = -1
  WHERE  a = 982;

UPDATE ternary
SET    c = -1
WHERE  a = 982;


-- To reflect the above updates for current user/transaction, make
-- sure take visibility and delta BATs into account when we compute
-- the query's result:
EXPLAIN
  SELECT t.c
  FROM   ternary AS t;

SELECT t.*
FROM   ternary AS t;




-----------------------------------------------------------------------
-- To prepare the MAL session below, recreate the original
-- ternary(a,b,c) table and populate it:

DROP TABLE IF EXISTS ternary;
CREATE TABLE ternary (a int NOT NULL, b text NOT NULL, c double);

INSERT INTO ternary(a, b, c)
  SELECT value, md5(value), log10(value)
  FROM   generate_series(1, 1001);


-----------------------------------------------------------------------
-- ⚠️ Talking MAL to MonetDB (mclient ... -lmsql)

-- Let us replay the above on the MAL level such that
-- - we can see the current contents of the visibility and delta tables
-- - simulate the application of this change information to the original
--   column BAT:
sql := sql.mvc();

-- DELETE FROM ternary WHERE a = 981;
ternary     :bat[:oid] := sql.tid(sql, "sys", "ternary");
a0          :bat[:int] := sql.bind(sql, "sys", "ternary", "a", 0:int);
deleted_rows:bat[:oid] := algebra.thetaselect(a0, ternary, 981:int, "==");
-- affects the visibility BAT
sql_delete             := sql.delete(sql, "sys", "ternary", deleted_rows);

io.print(deleted_rows);

-- UPDATE ternary SET c = -1 WHERE a = 982;
ternary:bat[:oid]  := sql.tid(sql, "sys", "ternary");
io.print(ternary);

updated_rows  :bat[:oid] := algebra.thetaselect(a0, ternary, 982:int, "==");
updated_c     :bat[:dbl] := algebra.project(updated_rows, -1:dbl);
-- affects the Δᵘ BAT
sql_update               := sql.update(sql, "sys", "ternary", "c", updated_rows, updated_c);

io.print(updated_rows, updated_c);

-- INSERT INTO ternary(a,b,c) VALUES (1001, 'Han Solo', -2);
-- the following three affect the Δⁱ BATs
sql_append := sql.append(sql, "sys", "ternary", "a", 1001:int);
sql_append := sql.append(sql, "sys", "ternary", "b", "Han Solo");
sql_append := sql.append(sql, "sys", "ternary", "c", -2:dbl);

-- SELECT t.c FROM ternary AS t;
ternary:bat[:oid] := sql.tid(sql, "sys", "ternary");
c0     :bat[:dbl] := sql.bind(sql, "sys", "ternary", "c", 0:int);

io.print(ternary);

-- the original column BAT has not been updated yet:
io.print(c0);

-- access and dump the Δ BATs using sql.bind(..., 1) and sql.bind(..., 2):
inserted_c:bat[:dbl]                          := sql.bind(sql, "sys", "ternary", "c", 1:int);
(updated_rows:bat[:oid], updated_c:bat[:dbl]) := sql.bind(sql, "sys", "ternary", "c", 2:int);

io.print(inserted_c);

io.print(updated_rows, updated_c);

-- implement changes (this is equivalent to sql.delta(sql, c0, updated_rows, updated_c, inserted_c)):
-- apply Δᵘ
bat.replace(c0, updated_rows, updated_c, true);
-- apply Δⁱ
bat.append(c0, inserted_c);
-- apply visibility
c:bat[:dbl] := algebra.projection(ternary, c0);

-- this computed BAT has all updates applied and reflects the effects
-- of the above SQL DML statements:
io.print(c);
