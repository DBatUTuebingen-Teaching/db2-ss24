# DB2 Docker Setup

In this lecture, we rely on [monetdb 11.35](https://www.monetdb.org/release-notes/nov2019/) and [PostgreSQL >15.6](https://www.postgresql.org/docs/current/index.html).

## Installation

For simplicity, we recommend installing the most recent versions of the respective clients (`mclient` for monetdb and `psql` for PostgreSQL) and running the respective servers of the appropriate versions through [docker](https://www.docker.com).

### Installing the **servers**

If you still need a docker installation, follow their [documentation](https://docs.docker.com/desktop/) to get it up and running on your system. Once you have docker installed, you have two options to get up and running: via the `Makefile` we've provided you or by hand. We recommend using the `Makefile` as it streamlines the whole process, but if you are on a system without access to `make`, installing manually is the most direct method.

#### Installing via the `Makefile`

1. Use your shell to navigate to the directory containing the `docker-compose.yml` and `Makefile` files we've provided.
2. Run `make setup` to download and configure the servers.
3. Afterwards you can run `make start` to start the servers.
4. You can freely navigate away from the current directory and access the databases through their respective clients, as shown below.
5. If you want to stop the servers again, navigate back to the directory with the `docker-compose.yml` and `Makefile` files and run `make stop`. Then, to start them again, run `make start` as before.

#### Installing manually

1. Use your shell to navigate to the directory containing the `docker-compose.yml` file we've provided.
2. Start the servers via `docker compose up -d`. Note that the first time you do this, docker will most likely first pull, i.e., download the appropriate container images, so don't be surprised if you don't see this again afterwards.
3. Once the servers are up and running, you need to perform minimal setup operations, such as setting up databases within the DBMSs.
   * For *monetdb*, this boils down to the following:
      1. Creating the database via `docker compose exec monetdb monetdb create scratch`.
         * You can configure the database name by changing `scratch` to your desired name. If you do so, be sure to amend any of the following commands to reference this name appropriately.
      2. "Releasing" the database via `docker compose exec monetdb monetdb release scratch`.
   * For *PostgreSQL*, no extra steps are required since the container already provides a database called `postgres`. If you want to create a database with a custom name, follow the [documentation](https://www.postgresql.org/docs/12/manage-ag-createdb.html) accordingly.
4. You can freely navigate away from the current directory and access the databases through their respective clients, as shown below.
5. If you want to stop the servers again, navigate back to the directory with the `docker-compose.yml` file and run `docker compose down`. Then, to start them again, run `docker compose up -d` as before.

### Installing the **clients**

For both DBMSs, we recommend installing the most recent client through the official means for your OS. Do so by following the install instructions on the respective home pages ([monetdb](https://www.monetdb.org/easy-setup/), [PostgreSQL](https://www.postgresql.org/download/)).

> [!IMPORTANT]
> Please make sure that the installation processes of the respective clients don't configure corresponding servers to start automatically. These servers can and will interfere with those started and managed by docker. On Ubuntu, for example, you can get around this by not installing the `postgresql` package but rather the `postgresql-client` package, which only installs the client, circumventing the issue entirely.

> [!TIP]
> We recommend Windows users to install and run the clients within [WSL](https://learn.microsoft.com/de-de/windows/wsl/). This streamlines the process of installing and using the clients and allows you to easily circumvent many peculiarities of Windows that often lead to issues down the line.

## Usage

Once done with the installation and the servers are running, you can connect to them using the respective clients. Again, we've added streamlined options for this in the provided `Makefile`, through we list both options below.

* Run `make postgres` (or `psql -U postgres -h localhost`) to enter PostgeSQL's client shell.
* Run `make monetdb` (or `mclient -u monetdb -d scratch -l sql`) to enter monetdb's client shell. It will prompt you for a password, which is set to `monetdb` by default.
> [!NOTE]
> In the process of the lecture you will also need to enter monetdb's cliebt shell in a different language mode, i.e., MAL code. You can access this mode using `make monetdb-mal` instead of `make monetdb`.

Once in the respective shell, you can create/modify/delete tables, run queries, and interact with underlying data structures and program representations. The lectures will explain everything you need for your homework in due time.
