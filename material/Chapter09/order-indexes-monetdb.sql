-- ⚠️ Talking SQL to MonetDB (mclient -l sql)

-- Create and populate table indexed with one million rows
DROP TABLE IF EXISTS indexed;
CREATE TABLE indexed (a int PRIMARY KEY, b text, c numeric(3,2));

INSERT INTO indexed(a,b,c)
  SELECT value, md5(value), sin(value)
  FROM   generate_series(1,1000001);

-- Filter on column a
EXPLAIN
  SELECT i.b, i.c
  FROM   indexed AS i
  WHERE  i.a = 42;


-- Filter on column c
--
-- Note how MonetDB internally represents type numeric(3,2)
-- by short 16-bit integers in the range {-999, 999}
-- (look for the algebra.thetaselect(..., 42:sht, "==")). Nifty.
EXPLAIN
  SELECT i.b, i.c
  FROM   indexed AS i
  WHERE  i.c = 0.42;


-----------------------------------------------------------------------
-- ⚠️ Talking MAL to MonetDB (-l msql)

-- Demonstrate property inference for BATs

-- Strictly ascending tail
t := bat.new(:int);
bat.append(t, 1);
bat.append(t, 2);
bat.append(t, 3);
io.print(t);

(i1,i2) := bat.info(t);
io.print(i1,i2);

-- Destroy strict tail ordering
bat.append(t, 5);
bat.append(t, 4);
io.print(t);

-- Property tkey not detected :-(
(i1,i2) := bat.info(t);
io.print(i1,i2);

-- Restore strict ordering (removes tail value 5)
bat.delete(t, 3@0);
io.print(t);

-- Property tsorted not detected :-(
(i1,i2) := bat.info(t);
io.print(i1,i2);

-----------------------------------------------------------------------
-- Demonstrate tactical optimization in MonetDB.  For the following,
-- start the MonetDB server process mserver5 directly (don't use the
-- monetdbd daemon):
--
-- $ mserver5 --dbpath=(pwd)/data/scratch --set monet_vault_key=(pwd)/data/scratch/.vaultkey --algorithms


-- ⚠️ Talking MAL to MonetDB (mclient -l msql)

# Make order index functionality available on the MAL level
include orderidx;

# Create and populate BAT t with unordered tail
t := bat.new(:int);
bat.append(t, 40);
bat.append(t, 39);
bat.append(t, 42);
bat.append(t, 44);
bat.append(t, 43);
bat.append(t, 38);
bat.append(t, 41);
bat.append(t, 37);
bat.append(t, 45);
bat.append(t, 36);

io.print(t);

# Tactical optimization of selection over BAT t: uses full scan :-(
s := algebra.select(t, 40, 42, true, true, false);
io.print(s);

# Create order index for BAT t
bat.orderidx(t);
oidx :bat[:oid] := bat.getorderidx(t);
io.print(oidx);

# Q: which BAT properties does oidx have?  [ key(oidx), nonil(oidx) ]

# ⚠️ This is only for demonstration purposes.  The order index
#    is picked up automatically by algebra.select(), see below.
#
# Order index allows for rapid sorting of BAT t in terms of
# simple projection:
sorted :bat[:int] := algebra.projection(oidx,t);
io.print(sorted);

# Tactical optimization: algebra.select() now uses order index :-)
s := algebra.select(t, 40, 42, true, true, false);
io.print(s);


-----------------------------------------------------------------------
-- Demonstrate the on-the-fly creation of indexes if this seems
-- beneficial (e.g., to process GROUP BY, ORDER BY, ...)

-- ⚠️ Talking SQL to MonetDB (mclient -l sql)

-- (If needed:) Create a fresh instance of table 'indexed'
DROP TABLE IF EXISTS indexed;
CREATE TABLE indexed (a int PRIMARY KEY, b text, c numeric(3,2));

INSERT INTO indexed(a,b,c)
  SELECT value, md5(value), sin(value)
  FROM   generate_series(1,1000001);


-- Query MonetDB's system catalog for properties and index structures
-- of table 'indexed'
SELECT column, type, count, columnsize,
       hashes, imprints, sorted, "unique", orderidx
FROM  sys.storage('sys', 'indexed');


-- Perform ORDER BY on column c which can benefit from an order index
SELECT i.*
FROM   indexed AS i
ORDER BY i.c
--
LIMIT 10            -- added only to keep
OFFSET 999990;      -- output size small


-- Re-check properties and presence of index structures
SELECT column, type, count, columnsize, location,
       hashes, imprints, sorted, "unique", orderidx
FROM  sys.storage('sys', 'indexed');

-- See column 'location' for directory of BATs for each column,
-- in particular check for a persistent *.torderidx for column 'c'


-- Unfortunately, order indexes are static structures.  An update on
-- column 'c' invalidates the order index :-/
UPDATE indexed
SET    c = -1
WHERE  a = 42;


-- Re-check catalog once more to see that order index is indeed gone...
SELECT column, type, count, columnsize, location,
       hashes, imprints, sorted, "unique", orderidx
FROM  sys.storage('sys', 'indexed');

-- Persistent order index in file *.torderidx gone as well
