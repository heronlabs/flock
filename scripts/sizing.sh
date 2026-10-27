#!/usr/bin/env bash
#
# sizing.sh — compute the runner pool capacity (RUNNERS, RUNNER_CPUS,
# RUNNER_MEMORY) from the CPUs and memory Docker can use on this machine.
#
# Prints the three KEY=value lines on stdout and a short summary on stderr.
# With --write it also updates them in .env, leaving every other line as is.
# The formula is documented under "Sizing" in README.md.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GIB=1073741824
TMP_FILE=""
trap 'rm -f "$TMP_FILE"' EXIT

usage() {
  cat <<'EOF'
Usage: scripts/sizing.sh [options]

Compute RUNNERS, RUNNER_CPUS and RUNNER_MEMORY for this machine and print them
as KEY=value lines. Without --cpus/--memory it detects what Docker can use
(`docker info`, which on Docker Desktop is the VM's size), falling back to the
host's own CPUs and memory.

Options:
  --cpus N               CPUs Docker can use (default: detected)
  --memory N             memory Docker can use, in GiB: 16, 16G or 16GB
                         (default: detected, rounded up to a whole GiB)
  --reserve-cpus N       CPUs kept for the host (default: CPUs / 4, rounded down)
  --reserve-memory N     GiB kept for the host (default: memory / 4, rounded up,
                         at least 1)
  --cpus-per-runner N    CPU limit per runner, at most (default: 3)
  --memory-per-runner N  memory limit per runner in GiB, at most (default: 3,
                         at least 2)
  --write [FILE]         also set the three keys in FILE (default: the .env
                         next to docker-compose.yml), replacing existing lines
                         and appending missing ones; other lines are untouched
  -h, --help             show this help

On a dedicated server (nothing else runs on it) pass --reserve-cpus 0.
EOF
}

die() {
  echo "sizing.sh: $*" >&2
  exit 1
}

bad_arg() {
  echo "sizing.sh: $*" >&2
  echo "Run 'scripts/sizing.sh --help' for usage." >&2
  exit 2
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
}

# to_int OPTION VALUE MIN — print VALUE as a base-10 integer >= MIN.
to_int() {
  is_uint "$2" || bad_arg "$1 expects a whole number, got '$2'"
  local n=$((10#$2))
  [ "$n" -ge "$3" ] || bad_arg "$1 must be at least $3, got '$2'"
  echo "$n"
}

# to_gib OPTION VALUE MIN — like to_int, also accepting a G, GB or GiB suffix.
to_gib() {
  local v=$2
  case "$v" in
    *[Gg][Ii][Bb]) v=${v%???} ;;
    *[Gg][Bb]) v=${v%??} ;;
    *[Gg]) v=${v%?} ;;
  esac
  is_uint "$v" || bad_arg "$1 expects whole GiB (16, 16G or 16GB), got '$2'"
  to_int "$1" "$v" "$3"
}

min() {
  if [ "$1" -lt "$2" ]; then echo "$1"; else echo "$2"; fi
}

cpus=""
mem=""
cpus_src="--cpus"
mem_src="--memory"
reserve_cpus=""
reserve_mem=""
target_cpus=3
target_mem=3
write=false
env_file="$ROOT_DIR/.env"

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --write)
      write=true
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then
        env_file=$2
        shift
      fi
      shift
      ;;
    --cpus | --memory | --reserve-cpus | --reserve-memory | --cpus-per-runner | --memory-per-runner)
      [ $# -gt 1 ] || bad_arg "$1 requires a value"
      case "$1" in
        --cpus) cpus=$(to_int "$1" "$2" 1) ;;
        --memory) mem=$(to_gib "$1" "$2" 1) ;;
        --reserve-cpus) reserve_cpus=$(to_int "$1" "$2" 0) ;;
        --reserve-memory) reserve_mem=$(to_gib "$1" "$2" 0) ;;
        --cpus-per-runner) target_cpus=$(to_int "$1" "$2" 1) ;;
        --memory-per-runner) target_mem=$(to_gib "$1" "$2" 2) ;;
      esac
      shift 2
      ;;
    *)
      bad_arg "unknown option '$1'"
      ;;
  esac
done

# Fill in --cpus/--memory that were not given: `docker info` first (on Docker
# Desktop that is the VM, which is what the runners get), then the host.
# Memory is rounded up: the reported total is the installed (or VM) size minus
# what the kernel and firmware keep, e.g. ~15.5 GiB on a 16 GB host.
detect() {
  local info="" d_cpus="" d_bytes="" src="docker info" kb=""
  if info=$(docker info --format '{{.NCPU}} {{.MemTotal}}' 2>/dev/null); then
    read -r d_cpus d_bytes <<<"$info" || true
  fi
  if ! is_uint "$d_cpus" || ! is_uint "$d_bytes"; then
    echo "sizing.sh: docker info is unavailable, using this host's own CPUs and memory (on Docker Desktop, start it first so the VM's size is used)" >&2
    src="host"
    d_cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    if [ -r /proc/meminfo ]; then
      kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
      if is_uint "$kb"; then d_bytes=$((kb * 1024)); fi
    else
      d_bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
    fi
  fi
  if [ -z "$cpus" ]; then
    if ! is_uint "$d_cpus" || [ "$d_cpus" -lt 1 ]; then
      die "could not detect the CPU count, pass --cpus N"
    fi
    cpus=$d_cpus
    cpus_src=$src
  fi
  if [ -z "$mem" ]; then
    is_uint "$d_bytes" || die "could not detect the memory size, pass --memory N"
    mem=$(((d_bytes + GIB - 1) / GIB))
    [ "$mem" -ge 1 ] || die "could not detect the memory size, pass --memory N"
    mem_src=$src
  fi
}

if [ -z "$cpus" ] || [ -z "$mem" ]; then
  detect
fi

if [ -z "$reserve_cpus" ]; then
  reserve_cpus=$((cpus / 4))
fi
if [ -z "$reserve_mem" ]; then
  reserve_mem=$(((mem + 3) / 4))
  if [ "$reserve_mem" -lt 1 ]; then reserve_mem=1; fi
fi

avail_cpus=$((cpus - reserve_cpus))
avail_mem=$((mem - reserve_mem))
runner_cpus=$(min "$target_cpus" "$avail_cpus")
runner_mem=$(min "$target_mem" "$avail_mem")

if [ "$runner_cpus" -lt 1 ] || [ "$runner_mem" -lt 2 ]; then
  die "host too small: ${cpus} CPUs / ${mem} GiB minus the host reserve (${reserve_cpus} CPUs / ${reserve_mem} GiB) leaves ${avail_cpus} CPUs / ${avail_mem} GiB, but one runner needs at least 1 CPU and 2 GiB (compose reserves 1G per replica)"
fi

runners=$(min $((avail_cpus / runner_cpus)) $((avail_mem / runner_mem)))
if [ "$runners" -lt 1 ]; then runners=1; fi

{
  echo "Docker can use: ${cpus} CPUs (${cpus_src}), ${mem} GiB (${mem_src})"
  echo "Host reserve:   ${reserve_cpus} CPUs, ${reserve_mem} GiB"
  echo "Runner pool:    ${runners} x ${runner_cpus} CPUs / ${runner_mem}G = $((runners * runner_cpus)) CPUs, $((runners * runner_mem)) GiB"
} >&2

if [ "$write" = true ]; then
  [ -f "$env_file" ] || die "$env_file not found, create it first: cp .env.example .env"
  TMP_FILE=$(mktemp "${env_file}.XXXXXX") || die "cannot create a temp file next to $env_file"
  awk -v runners="$runners" -v cpus="$runner_cpus" -v mem="${runner_mem}G" '
    BEGIN {
      n = split("RUNNERS RUNNER_CPUS RUNNER_MEMORY", keys, " ")
      value["RUNNERS"] = runners
      value["RUNNER_CPUS"] = cpus
      value["RUNNER_MEMORY"] = mem
    }
    {
      key = $0
      sub(/=.*/, "", key)
      if (index($0, "=") && (key in value)) {
        print key "=" value[key]
        seen[key] = 1
        next
      }
      print
    }
    END {
      for (i = 1; i <= n; i++)
        if (!(keys[i] in seen)) print keys[i] "=" value[keys[i]]
    }
  ' "$env_file" >"$TMP_FILE"
  mv "$TMP_FILE" "$env_file"
  TMP_FILE=""
  echo "Wrote RUNNERS, RUNNER_CPUS and RUNNER_MEMORY to $env_file" >&2
fi

echo "RUNNERS=${runners}"
echo "RUNNER_CPUS=${runner_cpus}"
echo "RUNNER_MEMORY=${runner_mem}G"
