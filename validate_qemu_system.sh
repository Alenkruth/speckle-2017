#!/bin/bash
# validate_qemu_system.sh
#
# Sanity check for full-system BBV collection. Boots each FireMarshal
# IMAFD spec2017 workload (in --suite) under qemu-system-riscv64 with
# the libbbv.so plugin attached, with a SHORT instruction budget so
# each run finishes in seconds-to-minutes. Verifies that every workload
# produces a non-empty BBV file.
#
# Workloads are discovered dynamically from speckle/build/overlay/<suite>/
# and mapped to FireMarshal images in $IMG_BASE (handles `<bench>-workload*`
# splits like 657.xz_s).
#
# Sister to validate_qemu.sh (user-mode sanity) and bbv_qemu_system.sh
# (full collection run). Outputs go to a dedicated sanity directory so
# real BBV runs aren't touched.
#
# Usage:
#   ./validate_qemu_system.sh                                   # intspeed, all, 4 parallel, 5B insns
#   ./validate_qemu_system.sh --suite fpspeed
#   ./validate_qemu_system.sh --jobs 8 --max-insns 2000000000
#   ./validate_qemu_system.sh --workloads "648.exchange2_s 605.mcf_s"
#
# Outputs:
#   $BBV_DIR/<workload>.bb.0.bb
#   $BBV_DIR/<workload>.{stdout,stderr}
#   $BBV_DIR/sanity.log

set -u

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"

QEMU=/home/jht9sy/work/qemu/build/qemu-system-riscv64
BBV_PLUGIN=/home/jht9sy/work/qemu/build/contrib/plugins/libbbv.so
STOP_PLUGIN=/home/jht9sy/work/qemu/build/contrib/plugins/libstoptrigger.so
IMG_BASE=/home/jht9sy/work/chipyard/software/firemarshal/images/firechip
BBV_ROOT=/data/akrish/riscv-spec2017-bbvs/bbv-sanity
INTERVAL=100000000
MAX_INSNS=5000000000   # ~ a couple minutes per workload under qemu emulation
JOBS=4
MEM=32G   # SPEC2017 ref-input working sets: intspeed worst ~7GB (xz),
          # fpspeed worst ~13GB (roms). 32GB gives 2.5x headroom.
          # qemu allocates lazily, so unused pages cost nothing.
SUITE=intspeed
BBV_DIR_OVERRIDE=""
WORKLOADS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --suite)     SUITE=$2;             shift 2 ;;
    --workloads) read -r -a WORKLOADS <<< "$2"; shift 2 ;;
    --jobs)      JOBS=$2;              shift 2 ;;
    --max-insns) MAX_INSNS=$2;         shift 2 ;;
    --mem)       MEM=$2;               shift 2 ;;
    --bbv-dir)   BBV_DIR_OVERRIDE=$2;  shift 2 ;;
    --img-base)  IMG_BASE=$2;          shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -x "$QEMU" ]        || { echo "ERROR: $QEMU not found"; exit 1; }
[ -f "$BBV_PLUGIN" ]  || { echo "ERROR: $BBV_PLUGIN not found"; exit 1; }
[ -f "$STOP_PLUGIN" ] || { echo "ERROR: $STOP_PLUGIN not found"; exit 1; }

BBV_DIR=${BBV_DIR_OVERRIDE:-$BBV_ROOT/${SUITE}-fullsystem}

# --- Discover workloads if not explicitly listed ---
if [ ${#WORKLOADS[@]} -eq 0 ]; then
  BENCH_ROOT=$SPECKLE_DIR/build/overlay/$SUITE
  if [ ! -d "$BENCH_ROOT" ]; then
    echo "ERROR: $BENCH_ROOT does not exist" >&2
    exit 1
  fi
  for bench_dir in "$BENCH_ROOT"/*/; do
    bench=$(basename "$bench_dir")
    split_found=0
    for split_dir in "$IMG_BASE"/${bench}-workload*; do
      if [ -d "$split_dir" ]; then
        WORKLOADS+=("$(basename "$split_dir")")
        split_found=1
      fi
    done
    if [ $split_found -eq 0 ] && [ -d "$IMG_BASE/$bench" ]; then
      WORKLOADS+=("$bench")
    fi
  done
fi

if [ ${#WORKLOADS[@]} -eq 0 ]; then
  echo "ERROR: no workloads found for suite=$SUITE — built no FireMarshal images yet?" >&2
  exit 1
fi

mkdir -p "$BBV_DIR"
LOG=$BBV_DIR/sanity.log
echo "[$(date +%H:%M:%S)] Sanity Suite=$SUITE Workloads=${#WORKLOADS[@]} Jobs=$JOBS MaxInsns=$MAX_INSNS Interval=$INTERVAL Mem=$MEM" | tee "$LOG"
printf '  %s\n' "${WORKLOADS[@]}" | tee -a "$LOG"

run_one() {
  local w=$1
  local out=$BBV_DIR/$w.bb

  # Auto-detect: prefer nodisk, fall back to disk mode
  local bin disk_args mode
  if [ -f "$IMG_BASE/$w/$w-bin-nodisk" ]; then
    bin=$IMG_BASE/$w/$w-bin-nodisk
    disk_args=()
    mode=nodisk
  elif [ -f "$IMG_BASE/$w/$w-bin" ] && [ -f "$IMG_BASE/$w/$w.img" ]; then
    bin=$IMG_BASE/$w/$w-bin
    disk_args=( -drive "file=$IMG_BASE/$w/$w.img,format=raw,id=hd0,if=none" -device virtio-blk-device,drive=hd0 )
    mode=disk
  else
    echo "[$(date +%H:%M:%S)] SKIP $w (no nodisk or disk image found)" | tee -a "$LOG"
    return
  fi

  echo "[$(date +%H:%M:%S)] START $w ($mode)" | tee -a "$LOG"
  local t0=$(date +%s)
  "$QEMU" -M virt -m "$MEM" -nographic -bios none \
    -kernel "$bin" \
    "${disk_args[@]}" \
    -plugin "$BBV_PLUGIN,outfile=$out,interval=$INTERVAL" \
    -plugin "$STOP_PLUGIN,icount=$MAX_INSNS" \
    > "$BBV_DIR/$w.stdout" 2> "$BBV_DIR/$w.stderr"
  local rc=$?
  local dt=$(( $(date +%s) - t0 ))

  # Two markers from the boot command:
  #   BENCH_STARTED       — boot reached the benchmark line
  #   BENCH_EXIT_CODE=N   — benchmark finished and run.sh's $? was N
  # In sanity mode the icount stoptrigger usually halts qemu BEFORE the
  # benchmark exits, so a healthy validate run shows BENCH_STARTED present
  # but BENCH_EXIT_CODE absent → KILLED MID-RUN (expected). If BENCH_STARTED
  # is also missing, the boot itself failed before the bench could run.
  local bench_started=0
  local bench_rc
  grep -aq 'BENCH_STARTED' "$BBV_DIR/$w.stdout" 2>/dev/null && bench_started=1
  bench_rc=$(grep -a -m1 -oE 'BENCH_EXIT_CODE=[0-9-]+' "$BBV_DIR/$w.stdout" 2>/dev/null | tr -d '\r' | cut -d= -f2)
  bench_rc=${bench_rc:-?}

  if [ ! -s "${out}.0.bb" ]; then
    echo "[$(date +%H:%M:%S)] FAIL  $w (qemu rc=$rc, no BBV, ${dt}s)" | tee -a "$LOG"
    return
  fi

  local n=$(grep -c '^T:' "${out}.0.bb")
  if [ "$bench_started" = "0" ]; then
    echo "[$(date +%H:%M:%S)] FAIL  $w — $n intervals (${dt}s, qemu rc=$rc, bench NEVER STARTED)" | tee -a "$LOG"
  elif [ "$bench_rc" = "?" ]; then
    echo "[$(date +%H:%M:%S)] PASS  $w — $n intervals (${dt}s, qemu rc=$rc, bench KILLED MID-RUN — expected for icount cap)" | tee -a "$LOG"
  elif [ "$bench_rc" = "0" ]; then
    echo "[$(date +%H:%M:%S)] PASS  $w — $n intervals (${dt}s, qemu rc=$rc, bench rc=0 — finished BEFORE icount cap)" | tee -a "$LOG"
  else
    echo "[$(date +%H:%M:%S)] WARN  $w — $n intervals (${dt}s, qemu rc=$rc, BENCH FAILED rc=$bench_rc)" | tee -a "$LOG"
  fi
}

export -f run_one
export QEMU BBV_PLUGIN STOP_PLUGIN IMG_BASE BBV_DIR INTERVAL MAX_INSNS MEM LOG

active=0
for w in "${WORKLOADS[@]}"; do
  run_one "$w" &
  ((active++))
  if [ $active -ge $JOBS ]; then
    wait -n 2>/dev/null || wait
    ((active--))
  fi
done
wait

echo "[$(date +%H:%M:%S)] Sanity complete" | tee -a "$LOG"
echo
echo "=== BBV output check ==="
for w in "${WORKLOADS[@]}"; do
  bbv=$BBV_DIR/$w.bb.0.bb
  if [ ! -s "$bbv" ]; then
    echo "MISSING  $w"
  else
    n=$(grep -c '^T:' "$bbv")
    sz=$(du -sh "$bbv" | cut -f1)
    echo "OK       $w — $n intervals, $sz"
  fi
done
