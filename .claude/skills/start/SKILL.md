---
name: start
description: Point the runner pool at any GitHub org, stop all containers/images/volumes, size the pool for this machine if needed, start the GitHub Actions runners fresh, and schedule an hourly health-check loop. Workstations only, never a dedicated server.
user-invocable: true
argument-hint: "[org]"
allowed-tools: Bash CronCreate
---

# Start GitHub Actions Runners

Usage: `/start <org>` — e.g. `/start my-org`.

Runs on any workstation: Linux, macOS, or Windows (Claude Code in Git Bash). Never on a dedicated server or VPS — see "Dedicated server / VPS" in `README.md`. If this machine is one — e.g. the checkout lives under `/srv/`, where the README's server setup puts it — stop here without running anything and tell the user.

The whole pool (`RUNNERS` replicas, set in `.env`) registers to ONE org at a time. Switching orgs deregisters the runners from the current org and registers them on the new one; jobs queued in the old org wait until you switch back.

Execute these steps in order. Validate the requested org (Step 1's first check) before the `.env` check and Step 0, so an invalid name stops the skill before anything is torn down.

## Before Step 0 — Check `.env`

`docker-compose.yml` requires `ORG_NAME`, so `docker compose` refuses to parse it while `.env` is missing or has no `ORG_NAME`. Check which case applies:

```
if [ ! -f .env ]; then echo missing; elif grep -Eq '^ORG_NAME=.+' .env; then echo org-set; else echo no-org; fi
```

- `missing` — run `cp .env.example .env`, tell the user to fill in `ACCESS_TOKEN` in `.env` (the runners can't register without it) and then run `/start <org>` again, and stop. Never print the `ACCESS_TOKEN` line.
- `no-org` — this checkout's config could not have registered anything, so skip Step 0's `docker compose down` but still run its leftover-container check, then continue to Step 1, which writes the org.
- `org-set` — continue with Step 0.

## Step 0 — Clean slate (BEFORE changing the org)

Stop all running containers and remove images and volumes while `.env` still points at the org they are registered to (skip this `down` when the `.env` check printed `no-org`). This also deregisters the runners from the org they were on (the entrypoint runs `config.sh remove` on SIGTERM):

```
docker compose down -v --rmi all --remove-orphans
```

`--remove-orphans` also removes containers of services no longer in `docker-compose.yml` (e.g. the old per-runner `github-runner-1/2/3` services from before the single scaled `runner` service).

Runner container names are compose-generated and no longer contain the org, so find leftover runner containers by their compose service label instead (e.g. a previous `down` did not run, or a stray container from another checkout):

```
docker ps -a --filter label=com.docker.compose.service=runner --format '{{.Names}}'
```

The `down` above already removed this checkout's runners, so anything still listed is a leftover. That includes containers of the pre-rename `gh-actions-runner` compose project (names `gh-actions-runner-runner-N`; the project is now pinned to `flock`) — remove those with `docker compose -p gh-actions-runner down -v --remove-orphans` so they deregister. `docker rm -f` any other leftover.

## Step 1 — Select the org

The requested org is: `$ARGUMENTS`

- Validate first: if an org was given, it must be a GitHub org name — it matches `^[A-Za-z0-9][A-Za-z0-9-]*$` (letters, digits and hyphens, not starting with a hyphen). Anything else: stop and tell the user. Check it before using it in any command:

  ```
  printf '%s\n' '<org>' | grep -Eqx '[A-Za-z0-9][A-Za-z0-9-]*' && echo valid || echo invalid
  ```

- If no org was given, keep whatever `ORG_NAME` is already in `.env` and say which one it is. If `.env` has no `ORG_NAME`, ask the user which org to use.

Now that the old pool is down, write the org into `.env` (idempotent — replaces the line if present, appends otherwise; portable across GNU and BSD/macOS userlands, no `sed -i`):

```
ORG=<org>; TMP=$(mktemp .env.XXXXXX) && awk -v org="$ORG" '/^ORG_NAME=/ { print "ORG_NAME=" org; done = 1; next } { print } END { if (!done) print "ORG_NAME=" org }' .env > "$TMP" && mv "$TMP" .env; grep '^ORG_NAME=' .env
```

Never print the `ACCESS_TOKEN` line of `.env`.

## Step 2 — Size the pool (only if not sized yet)

If `.env` lacks any of `RUNNERS`, `RUNNER_CPUS` or `RUNNER_MEMORY`, compute them for this machine with `scripts/sizing.sh --write` (it detects the CPUs and memory Docker can use and only touches those three lines). Values already in `.env` are kept — never hand-pick hardware-specific numbers:

```
for k in RUNNERS RUNNER_CPUS RUNNER_MEMORY; do grep -q "^$k=" .env || { scripts/sizing.sh --write; break; }; done; grep -E '^(RUNNERS|RUNNER_CPUS|RUNNER_MEMORY)=' .env
```

## Step 3 — Start runners

Bring up the runners in detached mode:

```
docker compose up -d
```

Then verify every replica is up (one per `RUNNERS` in `.env`):

```
docker compose ps
```

Wait ~20 s, then confirm each runner registered:

```
for c in $(docker compose ps -q); do docker logs $c 2>&1 | grep -E 'Runner successfully added|Listening for Jobs|error|invalid' | tail -3; done
```

## Step 4 — Schedule hourly health check

Use CronCreate to schedule a recurring job (every hour, off the :00 mark) with:

- **cron:** `7 * * * *`
- **recurring:** true
- **prompt:** the health-check prompt below

Health-check prompt:

> Check the health of the GitHub Actions runners with `docker compose ps`. If any runner is not running, restart it with `docker compose up -d`. Clean up dangling images, stopped containers, and unused volumes with `docker image prune -f && docker container prune -f && docker volume prune -f`. Report the status.

## Step 5 — Run the first health check now

Execute the health-check prompt immediately (don't wait for the first cron fire). Clean up any dangling resources and report the status of every runner replica, and which org they are registered to.
