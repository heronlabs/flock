.PHONY: test lint config

test:
	bats test/

lint:
	shellcheck scripts/*.sh test/*.bats

config:
	docker compose --env-file .env.example config -q
