#!/bin/bash
# bbv_qemu_system.sh
#
# Boots each FireMarshal IMAFD spec2017 workload (in --suite) under
# qemu-system-riscv64 with the libbbv.so plugin attached, collecting
# full-system BBVs (kernel + benchmark interleaved) at 100M-instruction
# intervals.
#
# By default each workload runs to NATURAL COMPLETION (the workload's
# run.sh exits and the boot script issues `poweroff -f`, qemu exits
# cleanly). No instruction-count cap is applied unless --max-insns is
# explicitly passed. This matches run_qemu.sh's behavior. SimPoint
# clustering needs the FULL phase profile to be representative; capping
# would silently truncate benchmarks and bias the simpoints.
#
# Workloads are discovered dynamically from speckle/build/overlay/<suite>/.
# Same convention as run_qemu.sh / validate_qemu.sh. For each benchmark
# directory found, the corresponding FireMarshal image is located in
# $IMG_BASE — if a `<bench>-workload*` split exists (e.g. 657.xz_s split
# into 657.xz_s-workload0 and 657.xz_s-workload1) all splits are picked
# up; otherwise the single `<bench>` image is used.
#
# The qemu plugin in this tree (qemu/contrib/plugins/bbv.c) already
# shifts BB indices by +1, so SimPoint can consume the BBVs directly —
# no need to run fixup_bbvs.sh on these outputs.
#
# Usage:
#   ./bbv_qemu_system.sh                                   # intspeed, all workloads, run to completion
#   ./bbv_qemu_system.sh --suite fpspeed
#   ./bbv_qemu_system.sh --jobs 11
#   ./bbv_qemu_system.sh --workloads "648.exchange2_s 605.mcf_s"
#   ./bbv_qemu_system.sh --max-insns 50000000000        # OPT-IN cap (use only for debug/profiling)
#   ./bbv_qemu_system.sh --bbv-dir /tmp/bbv-test
#   ./bbv_qemu_system.sh --img-base /path/to/firemarshal/images/firechip
#
# Outputs:
#   $BBV_DIR/<workload>.bb.0.bb
#   $BBV_DIR/<workload>.{stdout,stderr}
#   $BBV_DIR/bbv.log

set -u

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"

QEMU=/home/jht9sy/work/qemu/build/qemu-system-riscv64
BBV_PLUGIN=/home/jht9sy/work/qemu/build/contrib/plugins/libbbv.so
STOP_PLUGIN=/home/jht9sy/work/qemu/build/contrib/plugins/libstoptrigger.so
IMG_BASE=/home/jht9sy/work/chipyard/software/firemarshal/images/firechip
BBV_ROOT=/data/akrish/riscv-spec2017-bbvs
INTERVAL=100000000
MAX_INSNS=0   # 0 = unbounded (no stoptrigger plugin attached). Set via --max-insns to opt in.
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
if [ "$MAX_INSNS" != "0" ]; then
  [ -f "$STOP_PLUGIN" ] || { echo "ERROR: $STOP_PLUGIN not found"; exit 1; }
fi

BBV_DIR=${BBV_DIR_OVERRIDE:-$BBV_ROOT/${SUITE}-fullsystem}

# --- Discover workloads if not explicitly listed ---
# Mirrors validate_qemu.sh: enumerate every directory under
# speckle/build/overlay/<suite>/ and map each to its FireMarshal image(s).
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
LOG=$BBV_DIR/bbv.log

if [ "$MAX_INSNS" = "0" ]; then
  CAP_DESC="unbounded"
else
  CAP_DESC="$MAX_INSNS"
fi
echo "[$(date +%H:%M:%S)] Suite=$SUITE Workloads=${#WORKLOADS[@]} Jobs=$JOBS MaxInsns=$CAP_DESC Interval=$INTERVAL Mem=$MEM" | tee "$LOG"
printf '  %s\n' "${WORKLOADS[@]}" | tee -a "$LOG"

run_one() {
  local w=$1
  local out=$BBV_DIR/$w.bb

  # Auto-detect: prefer nodisk (<w>-bin-nodisk) if it exists, fall back to
  # disk mode (<w>-bin + <w>.img + virtio-blk). This handles workloads like
  # 625.x264_s whose 1.7GB overlay is too large for initramfs — those only
  # have the disk variant. Everything else gets nodisk automatically.
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
  if [ -s "${out}.0.bb" ]; then
    echo "[$(date +%H:%M:%S)] SKIP $w (exists)" | tee -a "$LOG"
    return
  fi

  echo "[$(date +%H:%M:%S)] START $w ($mode)" | tee -a "$LOG"
  local t0=$(date +%s)

  # Build qemu command. stoptrigger is OPT-IN only (when MAX_INSNS > 0).
  local stop_args=()
  if [ "$MAX_INSNS" != "0" ]; then
    stop_args=( -plugin "$STOP_PLUGIN,icount=$MAX_INSNS" )
  fi

  "$QEMU" -M virt -m "$MEM" -nographic -bios none \
    -kernel "$bin" \
    "${disk_args[@]}" \
    -plugin "$BBV_PLUGIN,outfile=$out,interval=$INTERVAL" \
    "${stop_args[@]}" \
    > "$BBV_DIR/$w.stdout" 2> "$BBV_DIR/$w.stderr"
  local rc=$?
  local dt=$(( $(date +%s) - t0 ))

  # The boot command echoes two markers around run.sh:
  #   `BENCH_STARTED`        right before invoking the bench script
  #   `BENCH_EXIT_CODE=N`    after the script exits, before poweroff
  # If neither marker is present the boot itself failed before reaching the
  # benchmark (or the JSON was never rebuilt with the new command).
  # If only BENCH_STARTED is present, qemu was killed mid-benchmark
  # (icount cap, host SIGKILL/OOM, or crash).
  # If both are present, the benchmark ran and run.sh's $? is reliable.
  local bench_started=0
  local bench_rc
  grep -aq 'BENCH_STARTED' "$BBV_DIR/$w.stdout" 2>/dev/null && bench_started=1
  bench_rc=$(grep -a -m1 -oE 'BENCH_EXIT_CODE=[0-9-]+' "$BBV_DIR/$w.stdout" 2>/dev/null | tr -d '\r' | cut -d= -f2)
  bench_rc=${bench_rc:-?}

  if [ ! -s "${out}.0.bb" ]; then
    echo "[$(date +%H:%M:%S)] FAIL  $w (qemu rc=$rc, ${dt}s, no BBV) — see $BBV_DIR/$w.stderr" | tee -a "$LOG"
    return
  fi

  local n=$(grep -c '^T:' "${out}.0.bb")
  if [ "$bench_started" = "0" ]; then
    echo "[$(date +%H:%M:%S)] FAIL  $w — $n intervals, ${dt}s (qemu rc=$rc, bench NEVER STARTED — boot failed or JSON not rebuilt) — see $BBV_DIR/$w.stdout" | tee -a "$LOG"
  elif [ "$bench_rc" = "?" ]; then
    echo "[$(date +%H:%M:%S)] WARN  $w — $n intervals, ${dt}s (qemu rc=$rc, bench KILLED MID-RUN — icount cap, OOM, or qemu died)" | tee -a "$LOG"
  elif [ "$bench_rc" = "0" ]; then
    echo "[$(date +%H:%M:%S)] DONE  $w — $n intervals, ${dt}s (qemu rc=$rc, bench rc=0)" | tee -a "$LOG"
  else
    echo "[$(date +%H:%M:%S)] WARN  $w — $n intervals, ${dt}s (qemu rc=$rc, BENCH FAILED rc=$bench_rc) — see $BBV_DIR/$w.stdout" | tee -a "$LOG"
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

echo "[$(date +%H:%M:%S)] All jobs complete" | tee -a "$LOG"
echo
echo "=== Summary ==="
for w in "${WORKLOADS[@]}"; do
  bbv=$BBV_DIR/$w.bb.0.bb
  if [ ! -s "$bbv" ]; then
    echo "FAIL   $w — no output"
    continue
  fi
  n=$(grep -c '^T:' "$bbv")
  sz=$(du -sh "$bbv" | cut -f1)
  bench_started=0
  grep -aq 'BENCH_STARTED' "$BBV_DIR/$w.stdout" 2>/dev/null && bench_started=1
  bench_rc=$(grep -a -m1 -oE 'BENCH_EXIT_CODE=[0-9-]+' "$BBV_DIR/$w.stdout" 2>/dev/null | tr -d '\r' | cut -d= -f2)
  bench_rc=${bench_rc:-?}
  if [ "$bench_started" = "0" ]; then
    echo "FAIL   $w — $n intervals, $sz, bench NEVER STARTED (boot failed)"
  elif [ "$bench_rc" = "?" ]; then
    echo "WARN   $w — $n intervals, $sz, bench KILLED MID-RUN"
  elif [ "$bench_rc" = "0" ]; then
    echo "OK     $w — $n intervals, $sz, bench rc=0"
  else
    echo "WARN   $w — $n intervals, $sz, bench FAILED rc=$bench_rc (see $w.stdout)"
  fi
done
