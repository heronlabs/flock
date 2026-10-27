# 🐦 flock — Self-hosted GitHub Actions runners

> **Docker Compose stack** that runs a pool of identical, non-ephemeral GitHub Actions runners with Docker-in-Docker (DinD) for one GitHub organization at a time.

One scaled `runner` service, built on [myoung34/github-runner](https://github.com/myoung34/docker-github-actions-runner), registers every replica as an org-level runner. The pool's capacity is computed from the machine it runs on (`scripts/sizing.sh`), so the same files run on:

- a **Linux workstation** or desktop, next to your own workload;
- **Docker Desktop** on Windows (WSL2) or macOS;
- a **dedicated server or VPS**, pinned to one org;

on amd64 or arm64. Tool caches and inner Docker images persist per replica across restarts.

## Contents

- [Security](#security)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Sizing](#sizing)
- [Host profiles](#host-profiles): [Linux workstation](#linux-workstation) · [Docker Desktop](#docker-desktop-windows-wsl2--macos) · [Dedicated server / VPS](#dedicated-server--vps)
- [Switching orgs](#switching-orgs)
- [Using the runners in workflows](#using-the-runners-in-workflows)
- [Architecture](#architecture)
- [Common operations](#common-operations)
- [Upgrading from gh-actions-runner](#upgrading-from-gh-actions-runner)
- [Appendix — GPU runners](#appendix--gpu-runners)
- [Development](#development)

---

## Security

Read this before pointing the runners at an org.

- **The runners are root on the host.** Every replica runs `privileged: true` so its inner Docker daemon works (DinD). A job running on them can take over the machine, read the other replicas' data and reach your local network. Only serve orgs and repositories whose workflows you trust as much as a shell on this machine.
- **Never let public repositories use them.** Anyone can open a pull request against a public repository. Keep **Allow public repositories** off on the org's runner group (GitHub's default — Organization settings → Actions → Runner groups), and require approval before workflows from fork pull requests run (Settings → Actions → General; in private repositories leave **Run workflows from fork pull requests** off unless you need it). This repository's own CI runs on GitHub-hosted runners for the same reason.
- **One org per dedicated server.** A job from one org must never share a privileged host with another org's runners: a server runs one pool for one org.
- **Keep the token out of sight.** `ACCESS_TOKEN` in `.env` can register and remove runners for every org it covers. `.env` is gitignored — never commit it, paste it into an issue or print it. `docker compose config` without `-q` prints the resolved file, token included. Use the least-privileged token that works: a fine-grained PAT owned by the org with only **Self-hosted runners: read & write**; a classic `admin:org` PAT only when one checkout switches between orgs.
- **Runners keep state between jobs.** They are non-ephemeral: a replica keeps its workspace, tool cache and inner Docker images, so a job can see what earlier jobs left on disk. Don't share one pool between projects that must not see each other's files. Setting `EPHEMERAL: "true"` in the runner's `environment` gives a fresh runner per job, at the cost of a re-registration and empty caches each time.

---

## Requirements

- **Docker with the Compose v2 plugin** (`docker compose`), able to run privileged Linux containers:
  - Linux: Docker Engine — see [Install Docker Engine](https://docs.docker.com/engine/install/);
  - Windows: Docker Desktop with the WSL2 backend and Linux containers;
  - macOS: Docker Desktop.
- **amd64 or arm64.** The image builds for either, and each runner reports its architecture as `X64` or `ARM64`.
- **A GitHub organization** you administer and a **personal access token** for it (see [Security](#security) and `.env.example`). The runners register at org level.
- **bash** for `scripts/sizing.sh`: any Linux shell, the bash that ships with macOS, or Git Bash on Windows.
- Optional: [Claude Code](https://claude.com/claude-code), for the `/start <org>` and `/stop` commands in `.claude/skills/` (workstations only).

---

## Quick start

```bash
git clone https://github.com/heronlabs/flock.git && cd flock
cp .env.example .env
# Edit .env: set ACCESS_TOKEN and ORG_NAME
scripts/sizing.sh --write   # size the pool for this machine (see Sizing)
docker compose build        # runner image: base image + Node 22, one-time
docker compose up -d
docker compose ps           # one container per runner
```

Wait ~20 seconds, then confirm each runner registered. Keep this check bounded: `docker compose logs -f` never exits, so it hangs scripts and unattended sessions — only use `-f` by hand in a terminal you will Ctrl-C.

```bash
for c in $(docker compose ps -q); do docker logs "$c" 2>&1 | grep -E 'Runner successfully added|Listening for Jobs|error|invalid' | tail -3; done
```

Then open `https://github.com/organizations/<ORG_NAME>/settings/actions/runners`. You should see `RUNNERS` runners named `<ORG_NAME>-runner-<random>`, Idle, labelled `self-hosted`, `Linux`, `X64` or `ARM64`, `docker` and `test`.

With Claude Code on a workstation, `/start <org>` does all of this in one go once `.env` holds your `ACCESS_TOKEN` — without a `.env` it copies `.env.example` and stops so you can fill the token in — and `/stop` brings the pool down; see [Switching orgs](#switching-orgs). Pick the [host profile](#host-profiles) that matches the machine for its tuning and power settings.

---

## Sizing

`scripts/sizing.sh` computes `RUNNERS`, `RUNNER_CPUS` and `RUNNER_MEMORY` from the CPUs and memory Docker can use. It reads them from `docker info` — on Docker Desktop that is the VM, not the PC — and falls back to the host's own (`nproc` or `getconf`, then `/proc/meminfo` or `sysctl hw.memsize`). Detected memory is rounded up to a whole GiB, because a machine always reports a little less than it has (~15.5 GiB on a 16 GB host).

```bash
scripts/sizing.sh                        # print the values for this machine
scripts/sizing.sh --write                # also write them to .env, leaving every other line untouched
scripts/sizing.sh --cpus 8 --memory 16   # size a different machine
docker compose up -d                     # apply a new size
```

The formula:

1. **Keep a reserve for the host.** A quarter of the CPUs (rounded down) and a quarter of the memory (rounded up, at least 1 GiB) stay free for the OS, Docker itself and your own workload.
2. **Size one runner.** Up to 3 CPUs and 3 GiB, less if what remains is smaller. Test jobs (`npm ci` + jest/vitest, pytest, …) gain little past 2-3 parallel workers, and equal runners make a job take the same time whichever runner picks it up, so there is no need for label-based tiers.
3. **Fit as many runners as both CPUs and memory allow**, at least one. If what remains can't hold one runner with 1 CPU and 2 GiB (compose reserves 1 GiB per replica), the script stops with an error.

| Docker can use | Host reserve | `RUNNERS` / `RUNNER_CPUS` / `RUNNER_MEMORY` | Runners use |
|---|---|---|---|
| 1 CPU, 4 GB | 0 CPUs, 1 GiB | 1 / 1 / 3G | 1 CPU, 3 GiB |
| 2 CPUs, 8 GB | 0 CPUs, 2 GiB | 1 / 2 / 3G | 2 CPUs, 3 GiB |
| 8 CPUs, 16 GB | 2 CPUs, 4 GiB | 2 / 3 / 3G | 6 CPUs, 6 GiB |
| 12 CPUs, 16 GB | 3 CPUs, 4 GiB | 3 / 3 / 3G | 9 CPUs, 9 GiB |
| 16 CPUs, 32 GB | 4 CPUs, 8 GiB | 4 / 3 / 3G | 12 CPUs, 12 GiB |

Overrides (`scripts/sizing.sh --help` lists them all):

| Option | Default | Use it to |
|---|---|---|
| `--cpus N`, `--memory N` | detected | size for other numbers than Docker reports; `--memory` takes `16`, `16G` or `16GB` |
| `--reserve-cpus N` | CPUs ÷ 4, rounded down | pass `0` on a dedicated server, where nothing else needs CPU |
| `--reserve-memory N` | memory ÷ 4, rounded up, at least 1 | keep more (or less) GiB for the host |
| `--cpus-per-runner N` | 3 | run more, smaller runners (`2`) or fewer, bigger ones (`4`) |
| `--memory-per-runner N` | 3 (at least 2) | give memory-hungry jobs more room, e.g. `6` for large builds or browsers |
| `--write [FILE]` | the `.env` next to `docker-compose.yml` | write the three keys instead of only printing them |

Until `.env` has these keys, `docker-compose.yml` falls back to 1 runner with 1 CPU and 2G, which starts on any machine. `RUNNER_CPUS` must never exceed the CPUs Docker can use, or Docker refuses to start the container.

Each runner gets a CPU *limit* (CFS quota), not a pin: replicas float across all CPUs and the kernel balances them, so the host's core topology doesn't matter.

---

## Host profiles

Every machine runs its own, separate pool. Two pools can register to the same org — runner names get a random suffix, so they never collide.

### Linux workstation

A desktop or laptop you also work on. The default sizing reserve keeps a quarter of the machine for you.

1. Install Docker Engine with the Compose plugin ([docs](https://docs.docker.com/engine/install/)) and let your user run it without `sudo`:

   ```bash
   sudo usermod -aG docker "$USER"
   newgrp docker
   ```

2. Tune the host (optional, recommended when the pool runs 24/7). Each setting is explained so you know what it does.

   ```bash
   # ─── CPU governor ───────────────────────────────────────────────────────
   #
   # WHAT: How the CPU picks its clock speed.
   #
   # WHY:  A dynamic governor ramps to full speed the moment a CI job or
   #       your own work needs it (~1 ms reaction time) and drops back
   #       when everything is idle, saving power on a machine that sits
   #       idle between CI runs. "performance" keeps every core at max
   #       clock all the time — overkill here.
   #
   #       Check the driver with
   #       `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver`.
   #       With `amd-pstate-epp` (recent AMD CPUs) or `intel_pstate`,
   #       only `performance` and `powersave` exist, and `powersave` is NOT
   #       the old fixed-low-clock governor — it is the dynamic, EPP-driven
   #       equivalent of `ondemand`. Use it. With `acpi-cpufreq`, use
   #       `ondemand` instead.
   #
   echo powersave | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

   # Bias the EPP hint toward responsiveness (good for CI bursts; EPP drivers only)
   echo balance_performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference

   # Make it survive reboots (Debian/Ubuntu)
   sudo apt install -y cpufrequtils
   echo 'GOVERNOR="powersave"' | sudo tee /etc/default/cpufrequtils
   sudo systemctl restart cpufrequtils
   ```

   ```bash
   # ─── Swappiness: 10 ─────────────────────────────────────────────────────
   #
   # WHAT: How aggressively the kernel moves data from RAM to swap (0-100,
   #       default 60).
   #
   # WHY:  Runners and your own workload should stay in RAM — swap is ~100x
   #       slower. 10 means "only swap when RAM is almost full". Not 0, which
   #       risks the OOM killer shooting down processes when RAM fills up.
   #
   # ─── Inotify watchers + instances ───────────────────────────────────────
   #
   # WHAT: inotify lets programs watch files for changes. `max_user_watches`
   #       caps watched files; `max_user_instances` caps inotify groups per
   #       user.
   #
   # WHY:  Several runners, their builds and your editors all create
   #       watchers. One Node project with node_modules can need 10,000+;
   #       common distro defaults (65536 / 128) run out fast and cause
   #       ENOSPC / "too many open files" errors. 524288 / 1024 are the
   #       usual VS Code / JetBrains values. No RAM is used until watchers
   #       are actually created.
   #
   # NOTE: `fs.file-max` is NOT set — modern kernels default to ~9.2
   #       quintillion, so there is nothing to raise.
   #
   # Write the whole tuning file in one shot (idempotent — safe to re-run)
   sudo tee /etc/sysctl.d/99-runner-tuning.conf > /dev/null <<'EOF'
   vm.swappiness=10
   fs.inotify.max_user_watches=524288
   fs.inotify.max_user_instances=1024
   EOF

   # Apply now (no reboot needed)
   sudo sysctl --system
   ```

3. Follow the [Quick start](#quick-start), or run `/start <org>` from Claude Code in the checkout.
4. Keep the machine from suspending while the pool should serve jobs — a sleeping machine takes its runners offline.

### Docker Desktop (Windows WSL2 / macOS)

The runners are the same Linux containers, run inside Docker Desktop's VM — not native Windows or macOS runners — so they register as `Linux` runners with the VM's architecture: `X64` on most Windows PCs, `ARM64` on Apple silicon Macs. Size against the VM, not the computer: `scripts/sizing.sh` reads `docker info`, which reports the VM's CPUs and memory, so start Docker Desktop first. Whatever the VM doesn't get stays for the OS and your apps; the default reserve keeps headroom inside the VM for Docker Desktop itself.

**Windows**

1. Install WSL2 from an admin PowerShell with `wsl --install`, then reboot.
2. Install Docker Desktop. Keep **Use the WSL 2 based engine** checked (Settings → General) and leave it on Linux containers (the default).
3. Enable **Start Docker Desktop when you sign in to your computer** (Settings → General). With `restart: always`, the runners come back whenever Docker Desktop starts — after a reboot, that is once you sign in.
4. Install Git for Windows. Run `scripts/sizing.sh`, the Quick start commands and Claude Code from Git Bash.
5. Keep the PC from sleeping while the pool should serve jobs (Settings → System → Power).
6. Size the VM. By default WSL2 gets half of Windows' RAM and every logical processor. To change that, edit `%UserProfile%\.wslconfig`:

   ```ini
   [wsl2]
   # Leave Windows and your apps enough outside the VM
   memory=<N>GB
   processors=<N>
   swap=<N>GB
   ```

   Apply it from PowerShell with `wsl --shutdown`, restart Docker Desktop, then run `scripts/sizing.sh --write`.

7. Optional kernel tuning. The CPU governor and `/etc/sysctl.d` file from the [Linux workstation](#linux-workstation) profile don't apply — Windows manages its own power plan and the runners' kernel is the WSL2 VM's. Check the VM's values first, Docker Desktop may already set them:

   ```bash
   docker run --rm alpine sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances vm.swappiness
   ```

   If they are below 524288 / 1024 / 10, set them at VM boot with the kernel's `sysctl.` boot parameters in the same `[wsl2]` section of `.wslconfig`, then `wsl --shutdown`, restart Docker Desktop and re-run the check. If a value doesn't change, something later in the VM's boot overrides it — leave it.

   ```ini
   kernelCommandLine = sysctl.fs.inotify.max_user_watches=524288 sysctl.fs.inotify.max_user_instances=1024 sysctl.vm.swappiness=10
   ```

**macOS**

1. Install Docker Desktop and enable **Start Docker Desktop when you sign in to your computer** (Settings → General).
2. Size the VM in Settings → Resources (CPU limit, memory limit, swap), then Apply & restart and run `scripts/sizing.sh --write`.
3. Keep the Mac awake while the pool should serve jobs (System Settings → Energy, or Battery → Options on a laptop; `caffeinate` works for a session).
4. On Apple silicon the runners are `ARM64`: target them with `[self-hosted, linux, arm64]`. Container images and tools published only for amd64 won't run on them as-is.

### Dedicated server / VPS

A machine that runs nothing but the pool, for **one org per server**. DinD runs `privileged: true`, which is effectively root on the host, so a job from one org must never share a machine with another org's runners.

> **Never run `/start` or `/stop` on a dedicated server.** `/start` runs `docker compose down -v` (dropping the caches a server keeps) and rewrites `ORG_NAME`, but a server is pinned to one org; `/stop` takes down the server's only pool. Its hourly health check also only fires while a Claude session is alive, and a server doesn't need it: `restart: always` brings the runners back after crashes and reboots. Never edit `ORG_NAME` on a server either.

1. **Bootstrap the OS** (e.g. Ubuntu 24.04): install Docker Engine with the Compose plugin ([docs](https://docs.docker.com/engine/install/)). On a small server, add a swapfile so a memory spike in a runner doesn't OOM the host — about the size of the RAM:

   ```bash
   sudo fallocate -l 4G /swapfile
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   ```

   Then write and apply the same `/etc/sysctl.d/99-runner-tuning.conf` as the [Linux workstation](#linux-workstation) profile (swappiness + inotify). The CPU-governor part doesn't apply to a VPS.

2. **Clone and configure:**

   ```bash
   sudo git clone https://github.com/heronlabs/flock.git /srv/flock
   sudo chown -R "$USER": /srv/flock
   cd /srv/flock
   cp .env.example .env
   nano .env
   ```

   - `ORG_NAME=<org>` — the single org this server serves.
   - `ACCESS_TOKEN=` a **fine-grained PAT** whose resource owner is that org, with the organization permission **Self-hosted runners: read & write**. A server should only hold a token scoped to its own org.

3. **Size the pool** with no CPU reserve, since nothing else runs on the machine (the memory reserve stays for the OS and Docker):

   ```bash
   scripts/sizing.sh --reserve-cpus 0 --write
   ```

4. **Build, start and check registration:**

   ```bash
   docker compose build && docker compose up -d
   for c in $(docker compose ps -q); do docker logs "$c" 2>&1 | grep -E 'Runner successfully added|Listening for Jobs|error|invalid' | tail -3; done
   ```

5. **Monitor** from the org's runners page (`<org>-runner-<random>`, Idle or Active) or from your workstation with `ssh <server> 'cd /srv/flock && docker compose ps'`.

Because nothing runs `docker compose down` on a server, the per-replica volumes (tool cache, inner Docker images) persist across restarts and reboots.

---

## Switching orgs

Workstations only — a dedicated server stays on its one org. A GitHub runner belongs to one org (sharing runners across orgs needs GitHub Enterprise), so the whole pool moves as a unit. The token in `.env` must be able to manage both orgs (a classic `admin:org` PAT from an owner of each).

With Claude Code, from the checkout:

```bash
/start my-org      # pool serves my-org
/start other-org   # pool serves other-org
```

`/start <org>` validates the name, runs `docker compose down -v --rmi all --remove-orphans` (which deregisters the runners from the old org), writes `ORG_NAME` to `.env`, runs `scripts/sizing.sh --write` if `.env` has no capacity yet, brings the pool up registered to the new org and schedules an hourly health check in that Claude session. `/stop` runs `docker compose down` and cancels the health check; the machine stays on.

By hand:

```bash
docker compose down -v   # deregisters the runners from the current org
# set ORG_NAME=<new-org> in .env
docker compose up -d
```

Always change the org in `.env` rather than with a shell export: the health check's `docker compose up -d` reads `.env`. Jobs queued in the org you left wait until you switch back. If a stale offline runner stays behind in the old org (e.g. the token could not deregister it), delete it from that org's runners page.

---

## Using the runners in workflows

Every runner is identical, so any of them can pick up a job:

```yaml
jobs:
  test:
    runs-on: [self-hosted, linux, x64]   # [self-hosted, linux, arm64] on an arm64 pool
    steps:
      - uses: actions/checkout@v7
      - run: npm ci && npm test
```

Labels match case-insensitively. Each runner carries:

- `self-hosted`, `Linux` and its architecture, `X64` or `ARM64` — added by the runner itself;
- `docker` and `test` — from `LABELS` in `docker-compose.yml`, whose default is `self-hosted,linux,docker,test`. Set `RUNNER_LABELS` in `.env` to replace that list, e.g. `RUNNER_LABELS=self-hosted,linux,docker,test,office` to target one pool with `runs-on: [self-hosted, office]`.

Workflows that use `runs-on: [self-hosted, linux, x64]` keep matching on amd64 hosts: `x64` comes from the runner's own architecture label, so an arm64 pool doesn't advertise it.

---

## Architecture

One `runner` service in `docker-compose.yml`, scaled to `RUNNERS` **identical** replicas (`deploy.replicas`), built from `runner.Dockerfile` on top of the `myoung34/github-runner` image and running in **Docker-in-Docker (DinD) mode**. The pool runs **tests**, so there is no heavy/light tier — every replica has the same CPU limit, memory limit and labels. Machine capacity lives in `.env` (`RUNNERS`, `RUNNER_CPUS`, `RUNNER_MEMORY`, written by `scripts/sizing.sh`), so the same compose file serves any host. The compose project is pinned with `name: flock`, so the project and its container names (`flock-runner-N`) don't depend on the checkout folder (a worktree, `/srv/flock`, a Windows path). Runner names come from `RUNNER_NAME_PREFIX=${ORG_NAME}-runner` plus the entrypoint's random 13-character suffix; `RUNNER_NAME` is deliberately unset, because it would override the prefix and give every replica the same name.

`runner.Dockerfile` exists because the base image (Ubuntu 20.04) ships the distro's `nodejs` package (v10.19.0) at `/usr/bin/node`, too old to run the runner's bundled `npm` — it breaks `pnpm/action-setup` and any action that shells out to `node`/`npm` via `PATH` instead of the runner's `externals/nodeXX`. The Dockerfile purges `nodejs`/`libnode64` and installs the official Node 22 LTS tarball for the build's architecture (`linux-x64` on amd64, `linux-arm64` on arm64, anything else fails the build) under `/usr/local`, which comes earlier on `PATH` and survives runner self-updates (unlike symlinking into `externals/`, which self-updates overwrite). To bump Node, set `NODE_VERSION` and both `NODE_SHA256_X64` / `NODE_SHA256_ARM64` from `https://nodejs.org/dist/v<version>/SHASUMS256.txt`, then `docker compose build`.

### What each docker-compose setting does

| Setting | Value | Purpose |
|---|---|---|
| `deploy.replicas` | `${RUNNERS:-1}` | Number of identical runner containers. Each registers as its own runner (`<org>-runner-<random>`). |
| `oom_score_adj` | `500` | Tells the Linux OOM killer to prefer killing runners over your own processes or the host's. Range -1000 to 1000; higher = killed first. |
| `shm_size` | `1g` | Size of `/dev/shm` (shared memory). Headless browsers (Chromium, Playwright, Cypress) crash if it is too small (Docker's default is 64 MB). |
| `tmpfs` | `/tmp/runner-tmp` | RAM-backed temporary directory. Faster than disk for build artifacts thrown away after the job. |
| `LABELS` | `${RUNNER_LABELS:-self-hosted,linux,docker,test}` | Labels added on top of the runner's own `self-hosted`, OS and architecture labels. |
| `DOCKERD_OPTS` | `overlay2`, `10 pulls` | The inner Docker daemon uses the overlay2 storage driver and downloads up to 10 image layers in parallel. |
| `ulimits.nofile` | `65536` | Max open files per container. Builds with many dependencies open thousands of files at once. |
| `ulimits.nproc` | `32768` | Max processes per container. Parallel builds (`make -j`, `npm run` scripts) spawn many child processes. |
| `logging` | `10m x 3` | Each container keeps at most 3 log files of 10 MB, so weeks of 24/7 running can't fill the disk. |
| `deploy.resources.limits` | `cpus: ${RUNNER_CPUS:-1}`, `memory: ${RUNNER_MEMORY:-2G}` | Per-replica hard ceiling, so a runaway build can't starve the host. `RUNNER_CPUS` must not exceed the CPUs Docker can use. |
| `deploy.resources.reservations` | `memory: 1G` | Memory floor so a runner can always start, even under load. No CPU reservation, so the config is valid on a 1-CPU host. |
| `/tmp/github-runner` volume | Anonymous, per replica | Runner work directory (checkouts, build output). |
| `/opt/hostedtoolcache` volume | Anonymous, per replica | Caches tool installs (`setup-node`, `setup-python`, …). |
| `/var/lib/docker` volume | Anonymous, per replica | Caches images pulled by the inner Docker daemon. |

The three volumes survive restarts and `docker compose up -d` recreates. `docker compose down` detaches them (a later `up` starts with empty caches, and the health check's `docker volume prune -f` deletes them); `down -v` deletes them at once. So on a workstation every `/start` begins with empty caches, while a dedicated server, which never runs `down`, keeps them.

Runner names get a **new random suffix** every time a container is recreated. If a runner stops without deregistering (crash, OOM, no network), its old name stays behind as an offline runner — delete it from the org's runners page.

---

## Common operations

```bash
# Stop all runners gracefully (deregisters them)
docker compose down

# Apply a change to .env or docker-compose.yml (e.g. a new size)
docker compose up -d

# Recreate every runner
docker compose up -d --force-recreate

# Check runner health
docker compose ps

# Live CPU, memory and network per container (Ctrl-C to exit)
docker stats

# Recent logs, bounded
docker compose logs --tail 50 runner

# Follow logs — interactive terminals only, never exits
docker compose logs -f runner

# Restart one runner without touching the others (names: docker compose ps)
docker restart flock-runner-2

# Reclaim disk space from unused images, containers and networks
docker system prune -f
```

---

## Upgrading from gh-actions-runner

Installs from before v1.2.0 ran as the compose project `gh-actions-runner` (containers `gh-actions-runner-runner-N`). `docker-compose.yml` now pins the project with `name: flock`, so on a machine still running the old pool the next `docker compose up -d` would start a second pool next to it. Take the old project down once first — `-p gh-actions-runner` targets it whatever the folder is called, and `-v` loses nothing, because the new project never reuses the old volumes.

Workstation, from the old checkout (it still holds `.env`):

```bash
docker compose -p gh-actions-runner down -v --remove-orphans   # deregisters the old runners
git remote set-url origin https://github.com/heronlabs/flock.git
git pull
docker image rm gh-actions-runner:node22   # optional — frees the old image
```

Then run `/start <org>` (or `scripts/sizing.sh --write` and `docker compose up -d`). If you skip the `down`, `/start` still finds the old containers: its leftover check lists runner containers by compose service label, which includes the old project's.

Dedicated server:

```bash
cd /srv/gh-actions-runner
docker compose -p gh-actions-runner down -v --remove-orphans   # deregisters the old runner
git remote set-url origin https://github.com/heronlabs/flock.git
git pull
cd /srv && sudo mv gh-actions-runner flock && cd flock   # optional — the old folder works too
docker compose build && docker compose up -d
docker image rm gh-actions-runner:node22   # optional — frees the old image
```

Afterwards, check the org's runners page and delete any offline runner the old pool left behind.

---

## Appendix — GPU runners

Only if you need a GPU inside a runner (CUDA builds, ML model tests). This needs a Linux host with an NVIDIA GPU and its driver installed (`nvidia-smi` works on the host).

1. Install the NVIDIA Container Toolkit, which lets Docker containers use the GPU:

   ```bash
   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
     sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
   curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
     sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
     sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
   sudo apt update && sudo apt install -y nvidia-container-toolkit

   # Configure Docker to use the NVIDIA runtime
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker

   # Verify the GPU is visible inside containers
   docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
   ```

2. Add a GPU reservation under the `reservations` section of the `runner` service in `docker-compose.yml`:

   ```yaml
             devices:
               - driver: nvidia
                 count: 1
                 capabilities: [gpu]
   ```

   and a `gpu` label in `.env`:

   ```bash
   RUNNER_LABELS=self-hosted,linux,docker,gpu
   ```

3. Target it from workflows:

   ```yaml
   jobs:
     ml-test:
       runs-on: [self-hosted, gpu]
       steps:
         - run: nvidia-smi
   ```

The reservation applies to every replica and one GPU can't be safely split between parallel jobs, so run a GPU pool with `RUNNERS=1`.

---

## Development

```bash
make lint     # shellcheck on scripts/ and test/
make test     # bats tests for scripts/sizing.sh and runner.Dockerfile
make config   # validate docker-compose.yml against .env.example
```

They need [bats-core](https://github.com/bats-core/bats-core), [ShellCheck](https://www.shellcheck.net/) and Docker. CI runs all three on GitHub-hosted runners for every pull request.

## License

[MIT](LICENSE)
