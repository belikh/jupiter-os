#!/usr/bin/env bash
#
# Parallel fleet status snapshot for the active build window. Probes every
# build host, the coordinator, and the deploy target concurrently via SSH,
# then prints a one-screen summary. Designed for the europa bring-up style
# of monitoring (callisto coordinating distributed kiosk builds, NFS-backed
# /nix/store, attic substituter, ZFS ARC health on the kiosks).
#
# What it reports per host:
#   - uptime / load / memory / swap
#   - top CPU procs (catches cc1plus / rustc / as / arc_prune pegging)
#   - active compiler counts (gcc/cc1plus/rustc/cargo/ld)
#   - ZFS ARC size + arc_prune CPU% (kiosks were burning 85% on this)
#   - NFS client state on callisto (mount + established conns)
#   - NFS server state on europa (nfsd threads + zpool iostat)
#   - rebuild wrapper alive + log size + recent log line (coordinator only)
#   - current-system hash + failed units (target only)
#
# Usage:
#   scripts/fleet-build-status.sh                # one-shot snapshot
#   scripts/fleet-build-status.sh --watch        # refresh every 30s
#   scripts/fleet-build-status.sh --watch 60     # refresh every 60s
#   scripts/fleet-build-status.sh --host callisto  # probe one host
#
# Hosts are hardcoded to match the jupiter-os fleet (CLAUDE.md). adrastea
# is included but typically offline (placeholder disks); probe will fail
# fast and the report marks it unreachable.

set -uo pipefail

# -- Fleet definition ----------------------------------------------------------
COORDINATOR="10.1.1.3"          # callisto — diskless netboot build coordinator
TARGET="10.1.1.2"               # europa — ZFS NAS, deploy target, NFS+attic server
KIOSKS=("amalthea.localdomain" "metis.localdomain" "thebe.localdomain" "adrastea.localdomain")

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=6 -o BatchMode=yes)

# -- Args ----------------------------------------------------------------------
watch=0
interval=30
single_host=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)    watch=1; shift; [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && { interval="$1"; shift; } ;;
    --host)     single_host="${2:?--host needs a value}"; shift 2 ;;
    -h|--help)  sed -n '1,/^set -uo/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)          echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# -- Per-host probe (runs on the remote via SSH) --------------------------------
# Output is prefixed with the host label so the collector can sort/section it.
probe_remote() {
  local host="$1" role="$2" label="$3"

  # The scriptlet runs on the remote host. Bash-safe (no bashisms that NixOS
  # /nix/store bash can't handle). Outputs labelled lines.
  ssh "${SSH_OPTS[@]}" "root@${host}" "
    label='${label}'
    role='${role}'
    out() { printf '%s|%s\n' \"\$label\" \"\$*\"; }

    out \"ROLE=\$role\"
    out \"TIME=\$(date +%H:%M:%S)\"
    out \"UP=\$(uptime | sed 's/^.*up /up /; s/,.*$//')\"
    out \"LOAD=\$(awk '{print \$1, \$2, \$3}' /proc/loadavg)\"
    out \"MEM=\$(free -h | awk '/^Mem:/{printf \"%s/%s used, %s avail\", \$3, \$2, \$7}')\"
    out \"SWAP=\$(free -h | awk '/^Swap:/{printf \"%s used\", \$3}')\"

    # Top 3 CPU procs (one line, comma-separated)
    out \"TOP=\$(ps -eo pcpu,comm --sort=-pcpu | awk 'NR>1 && \$1>0.5 {printf \"%s%% %s, \", \$1, \$2; c++} c>=3{exit}' | sed 's/, \$//')\"

    # Active compiler counts (bracket trick to avoid matching our own grep)
    out \"COMPILERS=gcc/cc1plus=\$(pgrep -c '[c]c1plus' 2>/dev/null || echo 0)+\$(pgrep -c '[/]g..\\+\\+' 2>/dev/null || echo 0) rustc/cargo=\$(pgrep -c '[r]ustc\\|[c]argo' 2>/dev/null || echo 0) ld=\$(pgrep -c '[/]ld\\b' 2>/dev/null || echo 0)\"

    # ZFS ARC + arc_prune (kiosks and europa have ZFS)
    if [ -r /proc/spl/kstat/zfs/arcstats ]; then
      arc_size=\$(awk '/^size /{print \$3}' /proc/spl/kstat/zfs/arcstats)
      arc_max=\$(awk '/^c_max /{print \$3}' /proc/spl/kstat/zfs/arcstats)
      pct=\$((arc_size * 100 / arc_max))
      out \"ARC=\$((arc_size / 1048576))MB/\$((arc_max / 1048576))MB (\${pct}%)\"
      apcpu=\$(ps -eo pcpu,comm 2>/dev/null | awk '\$2==\"arc_prune\"{s+=\$1} END{printf \"%.1f\", s+0}')
      out \"ARC_PRUNE=\${apcpu}%\"
    fi

    # Thermal: hottest zone + any throttle events this boot
    hottest=0
    hottest_type=\"\"
    for z in /sys/class/thermal/thermal_zone*; do
      [ -r \"\$z/temp\" ] || continue
      t=\$(cat \"\$z/temp\" 2>/dev/null)
      type=\$(cat \"\$z/type\" 2>/dev/null)
      if [ \"\$t\" -gt \"\$hottest\" ] 2>/dev/null; then
        hottest=\$t
        hottest_type=\$type
      fi
    done
    if [ \"\$hottest\" -gt 0 ]; then
      # x86_pkg_temp is the CPU die temp — most relevant for throttle
      pkg_temp=\$(awk -F: \"/x86_pkg_temp/{print \\\$2}\" /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1 | tr -d \" \")
      [ -z \"\$pkg_temp\" ] && pkg_temp=\$hottest
      out \"TEMP=pkg=\$((pkg_temp/1000))C max_zone=\$((hottest/1000))C (\$hottest_type)\"
    fi
    # Throttle indicator: count actual throttle events (NOT benign boot announcements).
    # Real events: "Core temperature above threshold", "Package temperature above threshold",
    # "clocks being throttled". Excludes "Thermal monitoring enabled", "Registered thermal governor".
    throt=\$(dmesg -T 2>/dev/null | grep -icE \"temperature above threshold|clocks being throttled|cpu clock throttled|thermal throttle\" || echo 0)
    out \"THROT_EVENTS=\$throt\"

    # NFS client state (callisto uses NFS-backed /nix/store)
    if mount | grep -q 'on /nix/store type nfs'; then
      conns=\$(ss -tn state established 2>/dev/null | grep -c ':2049\$' || echo 0)
      out \"NFS_CLIENT=store mounted, \$conns established conn(s) to server\"
    fi

    # NFS server state (europa serves /nix/store to callisto)
    if pgrep -x nfsd >/dev/null 2>&1; then
      threads=\$(pgrep -x nfsd | wc -l)
      out \"NFS_SERVER=\$threads nfsd threads\"
      if command -v zpool >/dev/null 2>&1; then
        # Second line of output is the 1-second sample (line 5 of total output);
        # cols are pool alloc free read_ops write_ops read_bytes write_bytes
        out \"ZPOOL=\$(zpool iostat tank 1 2 2>/dev/null | awk 'NR==5{printf \"%s+%s ops/s, %sB/s read, %sB/s write\", \$4, \$5, \$6, \$7}')\"
      fi
    fi
  " 2>&1 || echo "${label}|SHELL_ERROR: ssh probe failed"
}

# -- Coordinator-specific extras (rebuild wrapper + log) -----------------------
probe_coordinator_extras() {
  local host="$1"
  ssh "${SSH_OPTS[@]}" "root@${host}" "
    label='COORD'
    out() { printf '%s|%s\n' \"\$label\" \"\$*\"; }

    # Rebuild wrapper alive? Find the python nixos-rebuild-wrapped process.
    wrap_pid=\$(pgrep -f 'nixos-rebuild-wrapped' | head -1)
    if [ -n \"\$wrap_pid\" ]; then
      etime=\$(ps -o etime= -p \"\$wrap_pid\" | tr -d ' ')
      out \"REBUILD=wrapper pid=\$wrap_pid alive \$etime\"
    else
      out \"REBUILD=wrapper NOT running\"
    fi

    # Log size + 2s delta + last meaningful line — pick newest attempt log
    log=\$(ls -t /root/europa-rebuild-attempt*.log 2>/dev/null | head -1)
    if [ -n \"\$log\" ]; then
      s1=\$(stat -c%s \"\$log\")
      sleep 2
      s2=\$(stat -c%s \"\$log\")
      delta=\$((s2 - s1))
      last=\$(tail -1 \"\$log\" | tr -s ' ' | cut -c1-100)
      out \"LOG=\$(basename \$log) size=\$s2 delta_2s=\$delta\"
      out \"LAST=\$last\"
    fi
  " 2>&1
}

# -- Target-specific extras (current-system + failed units) --------------------
probe_target_extras() {
  local host="$1"
  ssh "${SSH_OPTS[@]}" "root@${host}" "
    label='TARGET'
    out() { printf '%s|%s\n' \"\$label\" \"\$*\"; }
    out \"CURRENT=\$(readlink /run/current-system 2>/dev/null | sed 's|/nix/store/||')\"
    out \"BOOTED=\$(readlink /run/booted-system 2>/dev/null | sed 's|/nix/store/||')\"
    out \"FAILED_UNITS=\$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l)\"
  " 2>&1
}

# -- Attic push check (any host) -----------------------------------------------
probe_attic() {
  local result=""
  for h in "${KIOSKS[@]}" "$COORDINATOR"; do
    # Skip if host is offline — we don't want a 6s timeout per dead host
    if ! ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "root@${h}" "true" 2>/dev/null; then
      continue
    fi
    local r
    r=$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "root@${h}" "
      pid=\$(pgrep -f '[a]ttic.*push' | head -1)
      if [ -n \"\$pid\" ]; then
        etime=\$(ps -o etime= -p \"\$pid\" | tr -d ' ')
        cmd=\$(ps -o cmd= -p \"\$pid\" | sed 's|.*/nix/store/[a-z0-9]*-||; s|/nix/store/[a-z0-9]*-||g' | cut -c1-80)
        printf 'running pid=%s etime=%s :: %s' \"\$pid\" \"\$etime\" \"\$cmd\"
      fi
    " 2>/dev/null)
    if [ -n "$r" ]; then
      result="${result}${h}: ${r}; "
    fi
  done
  echo "${result:-no attic push running anywhere}"
}

# -- Render --------------------------------------------------------------------
render() {
  # Collect probe outputs into temp files per section, then print.
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  local pids=()

  if [[ -z "$single_host" || "$single_host" == "callisto" || "$single_host" == "$COORDINATOR" ]]; then
    ( probe_remote "$COORDINATOR" "build-coordinator" "COORD" >"$tmpdir/coord.txt"
      probe_coordinator_extras "$COORDINATOR" >>"$tmpdir/coord.txt" ) &
    pids+=($!)
  fi
  if [[ -z "$single_host" || "$single_host" == "europa" || "$single_host" == "$TARGET" ]]; then
    ( probe_remote "$TARGET" "deploy-target+nfs-server" "TARGET" >"$tmpdir/target.txt"
      probe_target_extras "$TARGET" >>"$tmpdir/target.txt" ) &
    pids+=($!)
  fi
  for k in "${KIOSKS[@]}"; do
    if [[ -n "$single_host" && "$single_host" != "$k" && "$single_host" != "${k%%.*}" ]]; then
      continue
    fi
    ( probe_remote "$k" "kiosk-builder" "KIOSK:${k%%.*}" >"$tmpdir/${k%%.*}.txt" ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done

  # Attic check (sequential, but fast — just pgrep over SSH)
  local attic_state
  attic_state=$(probe_attic)

  # -- Print ------------------------------------------------------------------
  clear 2>/dev/null || true
  echo "==== jupiter-os fleet build status @ $(date +%H:%M:%S) ===="
  echo

  # Coordinator
  if [[ -f "$tmpdir/coord.txt" ]]; then
    awk -F'|' '
      $2 ~ /^ROLE=/   { role=$2;    sub(/^ROLE=/, "", role) }
      $2 ~ /^TIME=/   { timeln=$2;  sub(/^TIME=/, "", timeln) }
      $2 ~ /^UP=/     { up=$2;      sub(/^UP=/, "", up) }
      $2 ~ /^LOAD=/   { load=$2;    sub(/^LOAD=/, "", load) }
      $2 ~ /^MEM=/    { mem=$2;     sub(/^MEM=/, "", mem) }
      $2 ~ /^TOP=/    { top=$2;     sub(/^TOP=/, "", top) }
      $2 ~ /^COMPILERS=/ { comp=$2; sub(/^COMPILERS=/, "", comp) }
      $2 ~ /^NFS_CLIENT=/ { nfs=$2; sub(/^NFS_CLIENT=/, "", nfs) }
      $2 ~ /^TEMP=/   { temp=$2;    sub(/^TEMP=/, "", temp) }
      $2 ~ /^THROT_EVENTS=/ { throt=$2; sub(/^THROT_EVENTS=/, "", throt) }
      $2 ~ /^REBUILD=/ { rebuild=$2; sub(/^REBUILD=/, "", rebuild) }
      $2 ~ /^LOG=/     { logln=$2;  sub(/^LOG=/, "", logln) }
      $2 ~ /^LAST=/    { last=$2;   sub(/^LAST=/, "", last) }
      END {
        printf "[COORDINATOR] %s\n", role
        printf "  %s  %s  load: %s\n", timeln, up, load
        printf "  mem: %s\n", mem
        printf "  top: %s\n", top
        printf "  compilers: %s\n", comp
        printf "  nfs: %s\n", nfs
        printf "  thermal: %s  throttle_events: %s\n", temp, throt
        printf "  rebuild: %s\n", rebuild
        printf "  %s\n", logln
        printf "  last: %s\n", last
      }
    ' "$tmpdir/coord.txt"
    echo
  fi

  # Target
  if [[ -f "$tmpdir/target.txt" ]]; then
    awk -F'|' '
      $2 ~ /^ROLE=/   { role=$2;    sub(/^ROLE=/, "", role) }
      $2 ~ /^UP=/     { up=$2;      sub(/^UP=/, "", up) }
      $2 ~ /^LOAD=/   { load=$2;    sub(/^LOAD=/, "", load) }
      $2 ~ /^MEM=/    { mem=$2;     sub(/^MEM=/, "", mem) }
      $2 ~ /^ARC=/    { arc=$2;     sub(/^ARC=/, "", arc) }
      $2 ~ /^TEMP=/   { temp=$2;    sub(/^TEMP=/, "", temp) }
      $2 ~ /^THROT_EVENTS=/ { throt=$2; sub(/^THROT_EVENTS=/, "", throt) }
      $2 ~ /^NFS_SERVER=/ { nfs=$2; sub(/^NFS_SERVER=/, "", nfs) }
      $2 ~ /^ZPOOL=/  { zpool=$2;   sub(/^ZPOOL=/, "", zpool) }
      $2 ~ /^CURRENT=/ { cur=$2;    sub(/^CURRENT=/, "", cur) }
      $2 ~ /^BOOTED=/  { boot=$2;   sub(/^BOOTED=/, "", boot) }
      $2 ~ /^FAILED_UNITS=/ { fail=$2; sub(/^FAILED_UNITS=/, "", fail) }
      END {
        printf "[TARGET] %s\n", role
        printf "  %s  load: %s\n", up, load
        printf "  mem: %s\n", mem
        printf "  arc: %s\n", arc
        printf "  thermal: %s  throttle_events: %s\n", temp, throt
        printf "  nfs: %s\n", nfs
        printf "  zpool: %s\n", zpool
        if (cur == boot) {
          printf "  current-system: %s (UNCHANGED - still pre-rebuild gen)\n", cur
        } else {
          printf "  current-system: %s (NEW - activated)\n", cur
        }
        printf "  failed units: %s\n", fail
      }
    ' "$tmpdir/target.txt"
    echo
  fi

  # Kiosks
  for k in "${KIOSKS[@]}"; do
    local f="$tmpdir/${k%%.*}.txt"
    [[ -f "$f" ]] || continue
    awk -F'|' '
      $1 ~ /^KIOSK:/      { kioskhost=$1; sub(/^KIOSK:/, "", kioskhost) }
      $2 ~ /^SHELL_ERROR/ { err=err $2 " " }
      $2 ~ /^ROLE=/       { role=$2;    sub(/^ROLE=/, "", role) }
      $2 ~ /^UP=/         { up=$2;      sub(/^UP=/, "", up) }
      $2 ~ /^LOAD=/       { load=$2;    sub(/^LOAD=/, "", load) }
      $2 ~ /^MEM=/        { mem=$2;     sub(/^MEM=/, "", mem) }
      $2 ~ /^TOP=/        { top=$2;     sub(/^TOP=/, "", top) }
      $2 ~ /^COMPILERS=/  { comp=$2;    sub(/^COMPILERS=/, "", comp) }
      $2 ~ /^ARC=/        { arc=$2;     sub(/^ARC=/, "", arc) }
      $2 ~ /^ARC_PRUNE=/  { ap=$2;      sub(/^ARC_PRUNE=/, "", ap) }
      $2 ~ /^TEMP=/       { temp=$2;    sub(/^TEMP=/, "", temp) }
      $2 ~ /^THROT_EVENTS=/ { throt=$2; sub(/^THROT_EVENTS=/, "", throt) }
      END {
        printf "[KIOSK] %s (%s)\n", kioskhost, role
        if (err != "") { printf "  (probe error: %s)\n", err }
        else {
          printf "  %s  load: %s\n", up, load
          printf "  mem: %s\n", mem
          printf "  arc: %s  arc_prune: %s\n", arc, ap
          printf "  thermal: %s  throttle_events: %s\n", temp, throt
          printf "  compilers: %s\n", comp
          printf "  top: %s\n", top
        }
      }
    ' "$f"
    echo
  done

  # Attic
  echo "[ATTIC]"
  echo "  ${attic_state}"
  echo
}

# -- Main loop -----------------------------------------------------------------
if [[ "$watch" -eq 1 ]]; then
  while true; do
    render
    echo "(refreshing every ${interval}s, Ctrl-C to exit)"
    sleep "$interval"
  done
else
  render
fi
