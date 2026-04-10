#!/bin/bash
# validate_qemu_system.sh
#
# Sanity check for full-system BBV collection. Boots each FireMarshal
# IMAFD spec2017 intspeed workload under qemu-system-riscv64 with the
# libbbv.so plugin attached, with a SHORT instruction budget so each run
# finishes in seconds-to-minutes. Verifies that every workload produces a
# non-empty BBV file.
#
# Sister to validate_qemu.sh (user-mode sanity) and bbv_qemu_system.sh
# (full collection run). Outputs go to a dedicated sanity directory so
# real BBV runs aren't touched.
#
# Usage:
#   ./validate_qemu_system.sh                                   # all 11, 4 parallel, 5B insns
#   ./validate_qemu_system.sh --jobs 8 --max-insns 2000000000
#   ./validate_qemu_system.sh --workloads "648.exchange2_s 605.mcf_s"
#
# Outputs:
#   $BBV_DIR/<workload>.bb.0.bb
#   $BBV_DIR/<workload>.{stdout,stderr}
#   $BBV_DIR/sanity.log

set -u

QEMU=/home/jht9sy/work/qemu/build/qemu-system-riscv64
BBV_PLUGIN=/home/jht9sy/work/qemu/build/contrib/plugins/libbbv.so
STOP_PLUGIN=/home/jht9sy/work/qemu/build/contrib/plugins/libstoptrigger.so
IMG_BASE=/home/jht9sy/work/chipyard/software/firemarshal/images/firechip
BBV_DIR=/data/akrish/riscv-spec2017-bbvs/bbv-sanity/intspeed-fullsystem
INTERVAL=100000000
MAX_INSNS=5000000000   # 5B insns ~ a couple minutes per workload under qemu
JOBS=4

WORKLOADS=(
  600.perlbench_s 602.gcc_s 605.mcf_s 620.omnetpp_s 623.xalancbmk_s
  625.x264_s 631.deepsjeng_s 641.leela_s 648.exchange2_s
  657.xz_s-workload0 657.xz_s-workload1
)

while [[ $# -gt 0 ]]; do
  case $1 in
    --workloads) read -r -a WORKLOADS <<< "$2"; shift 2 ;;
    --jobs)      JOBS=$2;      shift 2 ;;
    --max-insns) MAX_INSNS=$2; shift 2 ;;
    --bbv-dir)   BBV_DIR=$2;   shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[ -x "$QEMU" ]        || { echo "ERROR: $QEMU not found"; exit 1; }
[ -f "$BBV_PLUGIN" ]  || { echo "ERROR: $BBV_PLUGIN not found"; exit 1; }
[ -f "$STOP_PLUGIN" ] || { echo "ERROR: $STOP_PLUGIN not found"; exit 1; }

mkdir -p "$BBV_DIR"
LOG=$BBV_DIR/sanity.log
echo "[$(date +%H:%M:%S)] Sanity Jobs=$JOBS MaxInsns=$MAX_INSNS Interval=$INTERVAL" | tee "$LOG"

run_one() {
  local w=$1
  local bin=$IMG_BASE/$w/$w-bin
  local img=$IMG_BASE/$w/$w.img
  local out=$BBV_DIR/$w.bb

  if [ ! -f "$bin" ] || [ ! -f "$img" ]; then
    echo "[$(date +%H:%M:%S)] SKIP $w (missing image)" | tee -a "$LOG"
    return
  fi

  echo "[$(date +%H:%M:%S)] START $w" | tee -a "$LOG"
  local t0=$(date +%s)
  "$QEMU" -M virt -m 4G -nographic -bios none \
    -kernel "$bin" \
    -drive "file=$img,format=raw,id=hd0,if=none" \
    -device virtio-blk-device,drive=hd0 \
    -plugin "$BBV_PLUGIN,outfile=$out,interval=$INTERVAL" \
    -plugin "$STOP_PLUGIN,icount=$MAX_INSNS" \
    > "$BBV_DIR/$w.stdout" 2> "$BBV_DIR/$w.stderr"
  local rc=$?
  local dt=$(( $(date +%s) - t0 ))

  if [ -s "${out}.0.bb" ]; then
    local n=$(grep -c '^T:' "${out}.0.bb")
    echo "[$(date +%H:%M:%S)] PASS  $w — $n intervals (${dt}s, qemu rc=$rc)" | tee -a "$LOG"
  else
    echo "[$(date +%H:%M:%S)] FAIL  $w (qemu rc=$rc, no BBV, ${dt}s)" | tee -a "$LOG"
  fi
}

export -f run_one
export QEMU BBV_PLUGIN STOP_PLUGIN IMG_BASE BBV_DIR INTERVAL MAX_INSNS LOG

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
