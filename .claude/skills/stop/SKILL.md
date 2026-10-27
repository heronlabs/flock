---
name: stop
description: Stop all GitHub Actions runner containers on a workstation (Linux, macOS or Windows) and cancel the hourly health check. The machine stays on. Never run on a dedicated server or VPS.
user-invocable: true
allowed-tools: Bash CronList CronDelete
---

# Stop GitHub Actions Runners

This skill is for workstations only (Linux, macOS, or Windows with Git Bash). Never run it on a dedicated server or VPS (see "Dedicated server / VPS" in `README.md`): it would take down the server's only pool. If this machine is one — e.g. the checkout lives under `/srv/`, where the README's server setup puts it — stop here without running anything and tell the user.

It only stops the runners; it never powers the machine off.

Execute these steps in order:

## Step 1 — Stop all containers

```
docker compose down
```

## Step 2 — Cancel the hourly health check

`/start` schedules an hourly health check that runs `docker compose up -d` when
a runner is down, so it would bring the pool back within the hour. Use
CronList to find that job in this session and CronDelete it. CronList only sees
this session's jobs: if there is none, a `/start` from another Claude session may
still have one scheduled — say so in the report, since that job would bring the
pool back within the hour until its session ends.

## Step 3 — Report

```
docker compose ps
```

Report that the pool is stopped (no runner listed) and that the machine is
still on. Run `/start <org>` to bring the pool back.
