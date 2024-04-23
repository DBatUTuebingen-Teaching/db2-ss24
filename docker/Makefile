monetdb_dbname  = scratch
docker_compose  = docker compose
postgres_client = psql
monetdb_client  = mclient

setup:
	@$(docker_compose) build
	@$(docker_compose) up -d --wait
	@$(docker_compose) exec monetdb monetdb create $(monetdb_dbname)
	@$(docker_compose) exec monetdb monetdb release $(monetdb_dbname)
	@$(docker_compose) down

start:
	@$(docker_compose) up -d --wait

stop:
	@$(docker_compose) down

postgres:
	@$(postgres_client) -U postgres -h localhost

monetdb:
	@$(monetdb_client) -u monetdb -d scratch

help:
	@echo "command  | description"
	@echo "---------+-----------------------------"
	@echo "help     | Show this help prompt."
	@echo "monetdb  | Open the monetdb shell."
	@echo "postgres | Open the postgres shell."
	@echo "setup    | Setup the containers."
	@echo "start    | Start the containers."
	@echo "stop     | Stop the running containers."

.PHONY: setup start stop clean postgres monetdb help