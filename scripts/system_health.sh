#!/usr/bin/env bash
#
# system_health.sh - lightweight host health check for production servers.
#
# Exit codes: 0 = healthy, 1 = warning (a threshold exceeded), 2 = critical, 3 = usage/runtime error.
set -euo pipefail

VERSION="1.0.0"
CPU_WARN=90
MEM_WARN=85
DISK_WARN=80
CRIT=95
LOAD_WARN=""            # default: number of CPU cores
INTERVAL=1
LOG_FILE="${HEALTH_LOG:-./health_log.txt}"
MAX_SIZE=$((1024 * 1024))
KEEP=5
JSON=0
WEBHOOK_URL="${HEALTH_WEBHOOK_URL:-}"

usage() {
  cat <<USAGE
Usage: ${0##*/} [options]

Collects CPU, memory, disk (all mounted filesystems), load average and the top 5
processes by memory; appends a timestamped entry to the log file.

Options:
  --cpu N          CPU warning threshold in percent        (default: ${CPU_WARN})
  --mem N          Memory warning threshold in percent     (default: ${MEM_WARN})
  --disk N         Disk warning threshold in percent       (default: ${DISK_WARN})
  --load N         1-min load average warning threshold    (default: number of CPU cores)
  --crit N         Critical threshold in percent for cpu/mem/disk (default: ${CRIT})
  --interval N     Seconds between CPU samples             (default: ${INTERVAL})
  --log-file PATH  Log file                                (default: \$HEALTH_LOG or ./health_log.txt)
  --max-size BYTES Rotate the log when it exceeds this     (default: ${MAX_SIZE})
  --keep N         Number of rotated logs to keep          (default: ${KEEP})
  --json           Output (and log) one JSON object per run instead of text
  -h, --help       Show this help
  -V, --version    Show version

Environment:
  HEALTH_LOG          default log file path
  HEALTH_WEBHOOK_URL  if set, a Slack/Discord-compatible webhook is notified on warning/critical

Exit codes: 0 healthy, 1 warning, 2 critical, 3 usage/runtime error.
USAGE
}

die() { echo "error: $*" >&2; exit 3; }

is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

need_value() { [[ $# -ge 2 ]] || die "option $1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)      need_value "$@"; CPU_WARN="$2"; shift 2 ;;
    --mem)      need_value "$@"; MEM_WARN="$2"; shift 2 ;;
    --disk)     need_value "$@"; DISK_WARN="$2"; shift 2 ;;
    --load)     need_value "$@"; LOAD_WARN="$2"; shift 2 ;;
    --crit)     need_value "$@"; CRIT="$2"; shift 2 ;;
    --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
    --log-file) need_value "$@"; LOG_FILE="$2"; shift 2 ;;
    --max-size) need_value "$@"; MAX_SIZE="$2"; shift 2 ;;
    --keep)     need_value "$@"; KEEP="$2"; shift 2 ;;
    --json)     JSON=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -V|--version) echo "${VERSION}"; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

CORES="$(nproc 2>/dev/null || echo 1)"
[[ -n "${LOAD_WARN}" ]] || LOAD_WARN="${CORES}"

for pair in "cpu:${CPU_WARN}" "mem:${MEM_WARN}" "disk:${DISK_WARN}" "crit:${CRIT}" "load:${LOAD_WARN}"; do
  is_number "${pair#*:}" || die "--${pair%%:*} must be a non-negative number (got '${pair#*:}')"
done
is_number "${INTERVAL}" || die "--interval must be a number"
is_uint "${MAX_SIZE}" || die "--max-size must be an integer number of bytes"
is_uint "${KEEP}" || die "--keep must be an integer"
for f in /proc/stat /proc/meminfo /proc/loadavg; do
  [[ -r "${f}" ]] || die "${f} not readable (this script requires Linux)"
done

# Float comparison helper: ge A B  ->  true when A >= B
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

json_escape() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "${s}"
}

# ---------------------------------------------------------------- CPU (two /proc/stat samples)
read_cpu() {
  local _ user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  echo "$((user + nice + system + idle + iowait + irq + softirq + steal)) $((idle + iowait))"
}
read -r total1 idle1 <<<"$(read_cpu)"
sleep "${INTERVAL}"
read -r total2 idle2 <<<"$(read_cpu)"
dtotal=$((total2 - total1))
didle=$((idle2 - idle1))
if [[ "${dtotal}" -gt 0 ]]; then
  CPU_PCT="$(awk -v t="${dtotal}" -v i="${didle}" 'BEGIN { printf "%.1f", (t - i) * 100 / t }')"
else
  CPU_PCT="0.0"
fi

# ---------------------------------------------------------------- Memory
MEM_TOTAL_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
MEM_AVAIL_KB="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
[[ -n "${MEM_TOTAL_KB}" && -n "${MEM_AVAIL_KB}" ]] || die "could not read memory info"
MEM_USED_MB=$(((MEM_TOTAL_KB - MEM_AVAIL_KB) / 1024))
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
MEM_PCT="$(awk -v t="${MEM_TOTAL_KB}" -v a="${MEM_AVAIL_KB}" 'BEGIN { printf "%.1f", (t - a) * 100 / t }')"

# ---------------------------------------------------------------- Load average
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg

# ---------------------------------------------------------------- Disks (all real mounted filesystems)
DISK_MOUNTS=()
DISK_PCTS=()
DISK_USED=()
while read -r _ blocks used _ pct mount; do
  [[ "${pct}" == *% ]] || continue
  DISK_MOUNTS+=("${mount}")
  DISK_PCTS+=("${pct%\%}")
  DISK_USED+=("$((used / 1024))/$((blocks / 1024))MB")
done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)

# ---------------------------------------------------------------- Top 5 processes by memory
TOP_PIDS=()
TOP_CMDS=()
TOP_MEMS=()
while read -r pid mem comm; do
  TOP_PIDS+=("${pid}")
  TOP_MEMS+=("${mem}")
  TOP_CMDS+=("${comm}")
done < <(ps -eo pid=,%mem=,comm= --sort=-%mem | sed -n '1,5p')

# ---------------------------------------------------------------- Evaluate thresholds
STATUS=0
WARNINGS=()
raise() { # raise <level 1|2> <message>
  [[ "$1" -gt "${STATUS}" ]] && STATUS="$1"
  WARNINGS+=("$2")
}
check_pct() { # check_pct <label> <value> <warn>
  if ge "$2" "${CRIT}"; then
    raise 2 "[CRITICAL] $1 usage ${2}% >= ${CRIT}%"
  elif ge "$2" "$3"; then
    raise 1 "[WARNING] $1 usage ${2}% exceeds threshold ${3}%"
  fi
}
check_pct "CPU" "${CPU_PCT}" "${CPU_WARN}"
check_pct "Memory" "${MEM_PCT}" "${MEM_WARN}"
for i in "${!DISK_MOUNTS[@]}"; do
  check_pct "Disk ${DISK_MOUNTS[i]}" "${DISK_PCTS[i]}" "${DISK_WARN}"
done
if ge "${LOAD1}" "${LOAD_WARN}"; then
  raise 1 "[WARNING] Load average (1m) ${LOAD1} exceeds threshold ${LOAD_WARN} (${CORES} cores)"
fi
case "${STATUS}" in 0) STATE="healthy" ;; 1) STATE="warning" ;; *) STATE="critical" ;; esac

# ---------------------------------------------------------------- Render
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST="$(hostname)"

render_json() {
  local i first sep
  printf '{"timestamp":"%s","host":"%s","status":"%s","exit_code":%d,' "${TS}" "$(json_escape "${HOST}")" "${STATE}" "${STATUS}"
  printf '"cpu_percent":%s,"memory":{"percent":%s,"used_mb":%d,"total_mb":%d},' "${CPU_PCT}" "${MEM_PCT}" "${MEM_USED_MB}" "${MEM_TOTAL_MB}"
  printf '"load_average":{"1m":%s,"5m":%s,"15m":%s,"cores":%d},"disks":[' "${LOAD1}" "${LOAD5}" "${LOAD15}" "${CORES}"
  sep=""
  for i in "${!DISK_MOUNTS[@]}"; do
    printf '%s{"mount":"%s","percent":%s}' "${sep}" "$(json_escape "${DISK_MOUNTS[i]}")" "${DISK_PCTS[i]}"
    sep=","
  done
  printf '],"top_memory_processes":['
  sep=""
  for i in "${!TOP_PIDS[@]}"; do
    printf '%s{"pid":%s,"command":"%s","memory_percent":%s}' "${sep}" "${TOP_PIDS[i]}" "$(json_escape "${TOP_CMDS[i]}")" "${TOP_MEMS[i]}"
    sep=","
  done
  printf '],"warnings":['
  first=1
  for i in "${!WARNINGS[@]}"; do
    [[ "${first}" -eq 1 ]] || printf ','
    printf '"%s"' "$(json_escape "${WARNINGS[i]}")"
    first=0
  done
  printf ']}\n'
}

render_text() {
  local i
  echo "=== System health @ ${TS} on ${HOST} [${STATE}] ==="
  echo "CPU:    ${CPU_PCT}%"
  echo "Memory: ${MEM_PCT}% (${MEM_USED_MB}/${MEM_TOTAL_MB} MB)"
  echo "Load:   ${LOAD1} ${LOAD5} ${LOAD15} (${CORES} cores)"
  echo "Disks:"
  for i in "${!DISK_MOUNTS[@]}"; do
    echo "  ${DISK_MOUNTS[i]}: ${DISK_PCTS[i]}% (${DISK_USED[i]})"
  done
  echo "Top 5 processes by memory:"
  for i in "${!TOP_PIDS[@]}"; do
    echo "  pid=${TOP_PIDS[i]} mem=${TOP_MEMS[i]}% cmd=${TOP_CMDS[i]}"
  done
  for w in "${WARNINGS[@]}"; do echo "${w}"; done
}

if [[ "${JSON}" -eq 1 ]]; then ENTRY="$(render_json)"; else ENTRY="$(render_text)"; fi

# ---------------------------------------------------------------- Log rotation + append
rotate_log() {
  local size i
  [[ -f "${LOG_FILE}" ]] || return 0
  size="$(wc -c <"${LOG_FILE}")"
  [[ "${size}" -gt "${MAX_SIZE}" ]] || return 0
  if [[ "${KEEP}" -eq 0 ]]; then
    : >"${LOG_FILE}"
    return 0
  fi
  rm -f "${LOG_FILE}.${KEEP}"
  for ((i = KEEP - 1; i >= 1; i--)); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
  done
  mv -f "${LOG_FILE}" "${LOG_FILE}.1"
}

mkdir -p "$(dirname "${LOG_FILE}")" || die "cannot create log directory"
(
  # Serialise concurrent runs (cron overlap) when flock is available.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${LOG_FILE}.lock"
    flock -w 10 9 || exit 3
  fi
  rotate_log
  if [[ "${JSON}" -eq 1 ]]; then
    printf '%s\n' "${ENTRY}" >>"${LOG_FILE}"
  else
    printf '%s\n\n' "${ENTRY}" >>"${LOG_FILE}"
  fi
) || die "could not write ${LOG_FILE}"

# ---------------------------------------------------------------- Output
if [[ "${JSON}" -eq 1 ]]; then
  printf '%s\n' "${ENTRY}"                     # stdout stays valid JSON
  for w in "${WARNINGS[@]}"; do echo "${w}" >&2; done
else
  printf '%s\n' "${ENTRY}"
fi

# Optional alerting (bonus): the webhook URL is read from the environment, never hardcoded.
if [[ -n "${WEBHOOK_URL}" && "${STATUS}" -gt 0 ]] && command -v curl >/dev/null 2>&1; then
  msg="$(printf '%s: %s\n' "${HOST}" "${WARNINGS[*]}")"
  payload="$(printf '{"text":"%s","content":"%s"}' "$(json_escape "${msg}")" "$(json_escape "${msg}")")"
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "${payload}" "${WEBHOOK_URL}" >/dev/null \
    || echo "warning: webhook notification failed" >&2
fi

exit "${STATUS}"
