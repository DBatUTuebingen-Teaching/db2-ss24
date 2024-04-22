-- Using table function generate_series() to create
-- sample table data "out of thin air".
--
-- Generate a single-column table of timestamp values i,
-- starting now with step width 1 minute:
SELECT i
FROM   generate_series('now'::timestamp,
                       'now'::timestamp + '1 hour',
                       '1 min') AS i;

-----------------------------------------------------------------------

-- Create and populate single-column table unary:
DROP TABLE IF EXISTS unary;
CREATE TABLE unary (a int);

-- Table unary will hold 100 rows of integers (recall:
-- there is NO guaranteed row order in a relational table):
INSERT INTO unary(a)
  SELECT i
  FROM   generate_series(1, 100, 1) AS i;

-- Reproduce all rows and all (here: the single) columns
-- of table unary in arbitrary order (probe query Q₁):
SELECT u.*
FROM   unary AS u;

-- Equivalent to Q₁: TABLE unary


-- Now use the DBMS x-ray!  PostgreSQL explains the plan it
-- will use to evaluate probe query Q₁:
EXPLAIN VERBOSE
  SELECT u.*
  FROM   unary AS u;

-----------------------------------------------------------------------

-- Show location in file system where PostgreSQL stores persistent data
-- (e.g., heap files):
show data_directory;

-- Query PostgreSQL's system catalog for all current databases
-- maintained by the DBMS:
SELECT db.oid, db.datname
FROM   pg_database AS db;

-- From the system catalog, retrieve the names of all tables as well
-- as the heap file names (column relfilenode) that hold the table data:
SELECT c.relfilenode, c.relname
FROM   pg_class AS c
ORDER BY c.relname DESC;


-- Create and populate a second unary table holding textual data
-- that we will able to identify when we peek inside the table's
-- heap file:
DROP TABLE IF EXISTS "unary'";
CREATE TABLE "unary'" (a text);
INSERT INTO "unary'" VALUES ('Yoda'), ('Han Solo'), ('Leia'), ('Luke');
TABLE "unary'";

-- Again, query the system catalog to retrieve the heap file name
-- for the new table unary':
SELECT c.relfilenode, c.relname
FROM   pg_class AS c
WHERE  c.relname = 'unary''';

-----------------------------------------------------------------------

-- Now remove all rows from our original table unary and re-populate
-- it with 1000 rows of integer data (the rows of this table will
-- occupy more than one page):
TRUNCATE unary;

INSERT INTO unary(a)
  SELECT i
  FROM   generate_series(1, 1000, 1) AS i;

SELECT c.relfilenode, c.relname
FROM   pg_class AS c
WHERE  c.relname = 'unary';


-- Access all rows and all columns in table unary AND ALSO output
-- the row IDs (RIDs, pseudo-column ctid) of all rows.  Note how the
-- first component p in the RIDs (p,_) indicates the page on which
-- the associated row is stored:
SELECT u.ctid, u.*
FROM   unary AS u;

-----------------------------------------------------------------------

-- Enable a PostgreSQL extension that enables us to peek inside the
-- free space maps (FSMs) maintainted for each heap file:
CREATE EXTENSION IF NOT EXISTS pg_freespacemap;


-- (Re-)create table unary with 1000 rows of integers:
DROP TABLE IF EXISTS unary;
CREATE TABLE unary (a int);
INSERT INTO unary(a)
  SELECT i
  FROM   generate_series(1, 1000, 1) AS i;

-- Locate the directory and heap file associated with table unary of
-- database scratch.  The FSM of the heap file has suffix '_fsm'.
show data_directory;

SELECT db.oid, db.datname
FROM   pg_database AS db
WHERE  db.datname = 'scratch';

SELECT c.relfilenode, c.relname
FROM   pg_class AS c
WHERE  c.relname = 'unary';

-- Query the leaf nodes of the current free space map for table unary
-- to check how many bytes are available on the heap file pages:
VACUUM unary;
SELECT *
FROM   pg_freespace('unary');


-- Delete a range of rows from table unary and recheck the available
-- space on the heap file pages:
DELETE FROM unary AS u
WHERE  u.a  BETWEEN 400 AND 500;

VACUUM unary;
SELECT *
FROM   pg_freespace('unary');


-- Insert a sentinel value into table unary so that we can easily
-- spot where the DBMS will place the new row in the heap file:
INSERT INTO unary(a) VALUES (-1);

VACUUM unary;
SELECT *
FROM   pg_freespace('unary');

TABLE unary;

SELECT u.ctid, u.a
FROM   unary AS u;

-- Perform a full vacuum run on table unary to reorganize the rows in the
-- heap file such that no space is wasted (remove all "holes" on the
-- pages):
VACUUM (VERBOSE, FULL) unary;
SELECT *
FROM   pg_freespace('unary');

-- Such a full vacuum run in fact creates a new heap file and marks the
-- old heap file as obsolete (OS file system can remove the file):
SELECT c.relfilenode, c.relname
FROM   pg_class AS c
WHERE  c.relname = 'unary';
