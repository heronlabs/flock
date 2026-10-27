# flock — agent instructions

flock is a Docker Compose stack of self-hosted GitHub Actions runners: one `runner` service (myoung34/github-runner, privileged Docker-in-Docker) scaled to identical replicas that register to ONE GitHub org at a time. It runs on Linux workstations, Docker Desktop (Windows WSL2 / macOS) and dedicated servers, amd64 or arm64.

The human guide is `README.md` — don't duplicate it here. Sections: Security, Requirements, Quick start, Sizing, Host profiles (Linux workstation · Docker Desktop · Dedicated server / VPS), Switching orgs, Using the runners in workflows, Architecture, Common operations, Upgrading from gh-actions-runner, Appendix — GPU runners, Development.

## Layout

- `docker-compose.yml` — the `runner` service; org, capacity and labels come from `.env` (`ORG_NAME`, `RUNNERS`, `RUNNER_CPUS`, `RUNNER_MEMORY`, `RUNNER_LABELS`).
- `runner.Dockerfile` — base image + Node 22 tarball per architecture (`NODE_SHA256_X64` / `NODE_SHA256_ARM64`).
- `scripts/sizing.sh` — computes the pool capacity from the CPUs and memory Docker can use; `test/sizing.bats` covers it.
- `.claude/skills/start`, `.claude/skills/stop` — `/start <org>` and `/stop`, workstations only.
- `version.txt`, `CHANGELOG.md` — managed by the Continuous Deployment workflow.

## Hard rules

- Never edit `version.txt` or `CHANGELOG.md`.
- Never commit `.env`, never print its `ACCESS_TOKEN` line, and never run `docker compose config` without `-q` (it prints the token).
- Never run `/start` or `/stop` on a dedicated server or VPS (e.g. a checkout under `/srv/`) — see README "Dedicated server / VPS".
- Size capacity with `scripts/sizing.sh` (`--write` updates `.env`). Never hand-pick hardware-specific numbers, and never write a specific machine, provider or org into docs, defaults or `.env.example`.
- Keep log checks bounded (`docker logs <c> 2>&1 | grep … | tail -3`). Never run `docker compose logs -f` or `docker logs -f` in an unattended session — they never exit.
- Never `docker compose up` just to test a change: it registers real runners to the org in `.env`. Use `make config` and `docker compose build`.
- CI and any workflow in this repo run on GitHub-hosted runners only, never `self-hosted`.
- Run `make lint` and `make test` (and `make config` when `docker-compose.yml` or `.env.example` changes) before opening a PR.
