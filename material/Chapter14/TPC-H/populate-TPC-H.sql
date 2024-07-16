-- Create and populate TPC-H tables
--
-- Run this SQL file from the shell via:
--
--  $ psql -f populate-TPC-H.sql

DROP TABLE IF EXISTS lineitem;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customer;
DROP TABLE IF EXISTS partsupp;
DROP TABLE IF EXISTS supplier;
DROP TABLE IF EXISTS part;
DROP TABLE IF EXISTS nation;
DROP TABLE IF EXISTS region;


CREATE TABLE region (
  r_regionkey  integer NOT NULL PRIMARY KEY,
  r_name       char(25) NOT NULL,
  r_comment    varchar(152));


CREATE TABLE nation (
  n_nationkey  integer NOT NULL PRIMARY KEY,
  n_name       char(25) NOT NULL,
  n_regionkey  integer NOT NULL,
  n_comment    varchar(152),
  FOREIGN KEY (n_regionkey) REFERENCES region
);


CREATE TABLE part (
  p_partkey     integer NOT NULL PRIMARY KEY,
  p_name        varchar(55) NOT NULL,
  p_mfgr        char(25) NOT NULL,
  p_brand       char(10) NOT NULL,
  p_type        varchar(25) NOT NULL,
  p_size        integer NOT NULL,
  p_container   char(10) NOT NULL,
  p_retailprice decimal(15,2) NOT NULL,
  p_comment     varchar(23) NOT NULL
);


CREATE TABLE supplier (
  s_suppkey     integer NOT NULL PRIMARY KEY,
  s_name        char(25) NOT NULL,
  s_address     varchar(40) NOT NULL,
  s_nationkey   integer NOT NULL,
  s_phone       char(15) NOT NULL,
  s_acctbal     decimal(15,2) NOT NULL,
  s_comment     varchar(101) NOT NULL,
  FOREIGN KEY (S_NATIONKEY) REFERENCES nation
);

CREATE TABLE partsupp (
  ps_partkey     integer NOT NULL,
  ps_suppkey     integer NOT NULL,
  ps_availqty    integer NOT NULL,
  ps_supplycost  decimal(15,2)  NOT NULL,
  ps_comment     varchar(199) NOT NULL,
  PRIMARY KEY (ps_partkey, ps_suppkey),
  FOREIGN KEY (ps_partkey) REFERENCES part,
  FOREIGN KEY (ps_suppkey) REFERENCES supplier
);

CREATE TABLE customer(
  c_custkey     integer NOT NULL PRIMARY KEY,
  c_name        varchar(25) NOT NULL,
  c_address     varchar(40) NOT NULL,
  c_nationkey   integer NOT NULL,
  c_phone       char(15) NOT NULL,
  c_acctbal     decimal(15,2)   NOT NULL,
  c_mktsegment  char(10) NOT NULL,
  c_comment     varchar(117) NOT NULL,
  FOREIGN KEY (c_nationkey) REFERENCES nation
);


CREATE TABLE orders (
  o_orderkey       integer NOT NULL PRIMARY KEY,
  o_custkey        integer NOT NULL,
  o_orderstatus    char(1) NOT NULL,
  o_totalprice     decimal(15,2) NOT NULL,
  o_orderdate      date NOT NULL,
  o_orderpriority  char(15) NOT NULL,
  o_clerk          char(15) NOT NULL,
  o_shippriority   integer NOT NULL,
  o_comment        varchar(79) NOT NULL
);


CREATE TABLE lineitem (
  l_orderkey      integer NOT NULL,
  l_partkey       integer NOT NULL,
  l_suppkey       integer NOT NULL,
  l_linenumber    integer NOT NULL,
  l_quantity      decimal(15,2) NOT NULL,
  l_extendedprice decimal(15,2) NOT NULL,
  l_discount      decimal(15,2) NOT NULL,
  l_tax           decimal(15,2) NOT NULL,
  l_returnflag    char(1) NOT NULL,
  l_linestatus    char(1) NOT NULL,
  l_shipdate      date not NULL,
  l_commitdate    date not NULL,
  l_receiptdate   date not NULL,
  l_shipinstruct  char(25) NOT NULL,
  l_shipmode      char(10) NOT NULL,
  l_comment       varchar(44) NOT NULL,
  PRIMARY KEY (l_orderkey, l_linenumber),
  FOREIGN KEY (l_partkey, l_suppkey) REFERENCES partsupp,
  FOREIGN KEY (l_orderkey) REFERENCES orders
);

\copy region   FROM 'region.tbl'   WITH (FORMAT csv, DELIMITER '|');
\copy nation   FROM 'nation.tbl'   WITH (FORMAT csv, DELIMITER '|');
\copy part     FROM 'part.tbl'     WITH (FORMAT csv, DELIMITER '|');
\copy supplier FROM 'supplier.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy partsupp FROM 'partsupp.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy customer FROM 'customer.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy orders   FROM 'orders.tbl'   WITH (FORMAT csv, DELIMITER '|');
\copy lineitem FROM 'lineitem.tbl' WITH (FORMAT csv, DELIMITER '|');
