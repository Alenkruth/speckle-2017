#!/bin/bash
# generate_checkpoints_fullsystem.sh
#
# Generates spike checkpoints at each SimPoint interval for each workload
# in the suite. For each (workload, simpoint), spike boots the full-system
# image, fast-forwards to the simpoint's instruction offset, dumps
# architectural state (loadarch) and memory (mem.elf), then exits.
#
# Auto-detects nodisk vs disk mode per workload (same logic as
# bbv_qemu_system.sh). For disk-mode workloads (e.g. 625.x264_s),
# spike is invoked with --extlib=libspikedevices.so --device=iceblk.
#
# Uses chipyard's generate-ckpt-pk.sh as the underlying checkpoint
# generator, adapted for full-system (no pk, direct kernel boot).
#
# Usage:
#   ./generate_checkpoints_fullsystem.sh                    # all workloads, 4 parallel
#   ./generate_checkpoints_fullsystem.sh --jobs 8
#   ./generate_checkpoints_fullsystem.sh --workloads "648.exchange2_s 605.mcf_s"
#   ./generate_checkpoints_fullsystem.sh --suite fpspeed
#
# Outputs:
#   $CKPT_DIR/<workload>/sp_<cluster>/loadarch
#   $CKPT_DIR/<workload>/sp_<cluster>/mem.elf
#   $CKPT_DIR/<workload>/sp_<cluster>/cmds_tmp.txt
#   $CKPT_DIR/<workload>/sp_<cluster>/spikecmd.sh

set -u

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"

RT=/home/jht9sy/work/chipyard/.conda-env/riscv-tools
SPIKE=$RT/bin/spike
OBJCOPY=$RT/bin/riscv64-unknown-elf-objcopy
LD=$RT/bin/riscv64-unknown-elf-ld
NM=$RT/bin/riscv64-unknown-elf-nm
READELF=$RT/bin/riscv64-unknown-elf-readelf
SPIKE_DEVICES=$RT/lib/libspikedevices.so

IMG_BASE=/home/jht9sy/work/chipyard/software/firemarshal/images/firechip
SIMPOINT_ROOT=/data/akrish/riscv-simpoints
CKPT_ROOT=/data/akrish/checkpoints
INTERVAL=100000000
ISA=rv64gc
MEM_BASE=0x80000000
MEM_SIZE=0x800000000   # 32GB — matches the QEMU BBV collection
JOBS=4
SUITE=intspeed
CKPT_DIR_OVERRIDE=""
SIMPOINT_DIR_OVERRIDE=""
WORKLOADS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --suite)         SUITE=$2;                  shift 2 ;;
    --workloads)     read -r -a WORKLOADS <<< "$2"; shift 2 ;;
    --jobs)          JOBS=$2;                   shift 2 ;;
    --isa)           ISA=$2;                    shift 2 ;;
    --ckpt-dir)      CKPT_DIR_OVERRIDE=$2;      shift 2 ;;
    --simpoint-dir)  SIMPOINT_DIR_OVERRIDE=$2;  shift 2 ;;
    --img-base)      IMG_BASE=$2;               shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -x "$SPIKE" ]    || { echo "ERROR: spike not found at $SPIKE"; exit 1; }
[ -x "$OBJCOPY" ]  || { echo "ERROR: objcopy not found at $OBJCOPY"; exit 1; }
[ -x "$LD" ]       || { echo "ERROR: ld not found at $LD"; exit 1; }

SIMPOINT_DIR=${SIMPOINT_DIR_OVERRIDE:-$SIMPOINT_ROOT/${SUITE}-fullsystem}
CKPT_DIR=${CKPT_DIR_OVERRIDE:-$CKPT_ROOT/${SUITE}-fullsystem}

if [ ! -d "$SIMPOINT_DIR" ]; then
  echo "ERROR: $SIMPOINT_DIR does not exist — run run_simpoint_fullsystem.sh first"
  exit 1
fi

# --- Discover workloads if not explicitly listed ---
if [ ${#WORKLOADS[@]} -eq 0 ]; then
  for sp_file in "$SIMPOINT_DIR"/*.simpoints; do
    [ -e "$sp_file" ] || continue
    WORKLOADS+=("$(basename "$sp_file" .simpoints)")
  done
fi

if [ ${#WORKLOADS[@]} -eq 0 ]; then
  echo "ERROR: no simpoints found in $SIMPOINT_DIR"
  exit 1
fi

mkdir -p "$CKPT_DIR"
LOG=$CKPT_DIR/checkpoint.log
echo "[$(date +%H:%M:%S)] Suite=$SUITE Workloads=${#WORKLOADS[@]} Jobs=$JOBS ISA=$ISA Interval=$INTERVAL" | tee "$LOG"
printf '  %s\n' "${WORKLOADS[@]}" | tee -a "$LOG"

generate_one_checkpoint() {
  local w=$1
  local cluster=$2
  local interval=$3

  local insn_offset=$(( interval * INTERVAL ))
  local insn_hex=$(printf "0x%x" "$insn_offset")
  local outdir=$CKPT_DIR/$w/sp_$cluster

  if [ -f "$outdir/mem.elf" ] && [ -s "$outdir/mem.elf" ] && [ -f "$outdir/loadarch" ]; then
    echo "[$(date +%H:%M:%S)] SKIP $w sp_$cluster (exists)" | tee -a "$LOG"
    return
  fi

  # Skip if a spike process is actively running for this checkpoint.
  # Prevents rm -rf from wiping in-progress work when the script is re-run
  # while a previous invocation still has jobs outstanding.
  if [ -d "$outdir" ] && pgrep -f "debug-cmd=$outdir/cmds_tmp.txt" >/dev/null 2>&1; then
    echo "[$(date +%H:%M:%S)] SKIP $w sp_$cluster (in progress)" | tee -a "$LOG"
    return
  fi

  # Auto-detect nodisk vs disk
  local bin spike_extra_args
  if [ -f "$IMG_BASE/$w/$w-bin-nodisk" ]; then
    bin=$IMG_BASE/$w/$w-bin-nodisk
    spike_extra_args=""
  elif [ -f "$IMG_BASE/$w/$w-bin" ] && [ -f "$IMG_BASE/$w/$w.img" ]; then
    bin=$IMG_BASE/$w/$w-bin
    spike_extra_args="--extlib=$SPIKE_DEVICES --device=iceblk,img=$IMG_BASE/$w/$w.img"
  else
    echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster (no image found)" | tee -a "$LOG"
    return
  fi

  rm -rf "$outdir"
  mkdir -p "$outdir"

  # Save the offset info for downstream tools
  echo "$insn_hex" > "$outdir/insn_offset.txt"
  echo "$insn_offset" >> "$outdir/insn_offset.txt"

  # Generate spike debug commands: fast-forward then dump state
  local cmds=$outdir/cmds_tmp.txt
  # spike's `rs` uses atoll() which only parses DECIMAL, not hex
  echo "rs $insn_offset" > "$cmds"
  echo "dump" >> "$cmds"
  echo "pc 0" >> "$cmds"
  echo "priv 0" >> "$cmds"
  echo "reg 0 fcsr" >> "$cmds"
  # Vector CSR reads are REQUIRED — chipyard's testchip_dtm.cc loadarch
  # parser expects exactly these 5 lines in this position (testchip_dtm.cc:216-220).
  # On a non-V spike these reads trap and produce "0xReceived trap: ..." lines;
  # std::stoull on those parses as 0, which is the correct reset state for
  # vstart/vxsat/vxrm/vcsr/vtype. Removing them shifts the line offsets and
  # makes the driver mis-read subsequent CSRs, eventually throwing out_of_range
  # from substr(18) in the FPR parsing loop.
  echo "reg 0 vstart" >> "$cmds"
  echo "reg 0 vxsat" >> "$cmds"
  echo "reg 0 vxrm" >> "$cmds"
  echo "reg 0 vcsr" >> "$cmds"
  echo "reg 0 vtype" >> "$cmds"
  echo "reg 0 stvec" >> "$cmds"
  echo "reg 0 sscratch" >> "$cmds"
  echo "reg 0 sepc" >> "$cmds"
  echo "reg 0 scause" >> "$cmds"
  echo "reg 0 stval" >> "$cmds"
  echo "reg 0 satp" >> "$cmds"
  echo "reg 0 mstatus" >> "$cmds"
  echo "reg 0 medeleg" >> "$cmds"
  echo "reg 0 mideleg" >> "$cmds"
  echo "reg 0 mie" >> "$cmds"
  echo "reg 0 mtvec" >> "$cmds"
  echo "reg 0 mscratch" >> "$cmds"
  echo "reg 0 mepc" >> "$cmds"
  echo "reg 0 mcause" >> "$cmds"
  echo "reg 0 mtval" >> "$cmds"
  echo "reg 0 mip" >> "$cmds"
  echo "reg 0 mcycle" >> "$cmds"
  echo "reg 0 minstret" >> "$cmds"
  echo "mtime" >> "$cmds"
  echo "mtimecmp 0" >> "$cmds"
  for fr in $(seq 0 31); do echo "freg 0 $fr" >> "$cmds"; done
  for xr in $(seq 0 31); do echo "reg 0 $xr" >> "$cmds"; done
  # vreg read: the driver (testchip_dtm.cc:255) checks for "VLEN=" on the
  # line immediately after GPRs. On a non-V spike the `vreg 0` command traps
  # and produces a non-VLEN line, which the driver treats as "no vector" and
  # skips. Including it keeps the line count correct for the parser.
  echo "vreg 0" >> "$cmds"
  echo "quit" >> "$cmds"

  # Save the spike command for reproducibility
  local spikecmd=$outdir/spikecmd.sh
  echo "$SPIKE -d --debug-cmd=$cmds $spike_extra_args --pmpregions=0 --isa=$ISA -p1 -m$MEM_BASE:$MEM_SIZE $bin" > "$spikecmd"
  chmod +x "$spikecmd"

  echo "[$(date +%H:%M:%S)] START $w sp_$cluster (interval=$interval, insns=$insn_hex, dec=$insn_offset)" | tee -a "$LOG"
  local t0=$(date +%s)

  # Run spike from inside the output directory so `dump` writes
  # mem.<addr>.bin there — avoids race when multiple jobs run in parallel.
  local loadarch=$outdir/loadarch
  echo 1 > "$loadarch"
  ( cd "$outdir" && \
    $SPIKE -d --debug-cmd="$cmds" \
      $spike_extra_args \
      --pmpregions=0 --isa=$ISA -p1 \
      -m$MEM_BASE:$MEM_SIZE \
      "$bin" 2>> "$loadarch" )

  local rc=$?
  local dt=$(( $(date +%s) - t0 ))

  # Convert the raw memory dump to an ELF — now in $outdir
  local mem_dump="$outdir/mem.$MEM_BASE.bin"
  if [ ! -f "$mem_dump" ]; then
    echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster (no memory dump after ${dt}s, spike rc=$rc)" | tee -a "$LOG"
    return
  fi

  local raw_elf=$outdir/raw.elf
  local mem_elf=$outdir/mem.elf

  $OBJCOPY -I binary -O elf64-littleriscv "$mem_dump" "$raw_elf"

  # Find tohost/fromhost symbols for HTIF
  local tohost fromhost
  tohost=$($NM "$bin" 2>/dev/null | awk '/ tohost$/ {print $1}' | head -1)
  fromhost=$($NM "$bin" 2>/dev/null | awk '/ fromhost$/ {print $1}' | head -1)

  if [ -n "$tohost" ] && [ -n "$fromhost" ]; then
    $LD -Tdata=$MEM_BASE -nmagic --defsym "tohost=0x$tohost" --defsym "fromhost=0x$fromhost" -o "$mem_elf" "$raw_elf"
  else
    $LD -Tdata=$MEM_BASE -nmagic -o "$mem_elf" "$raw_elf"
  fi

  rm -f "$raw_elf" "$mem_dump"

  # Validate the loadarch for errors spike may have dumped
  local ckpt_ok=1
  local fail_reason=""
  local pc=$(sed -n '3p' "$loadarch" | tr -d '[:space:]')
  if [ ! -f "$mem_elf" ] || [ ! -s "$mem_elf" ]; then
    ckpt_ok=0; fail_reason="mem.elf missing or empty"
  elif grep -q 'Kernel panic' "$loadarch" 2>/dev/null; then
    ckpt_ok=0; fail_reason="kernel panic in loadarch"
  elif [ "$pc" = "0x0000000000001000" ] || [ -z "$pc" ]; then
    ckpt_ok=0; fail_reason="PC stuck at reset vector ($pc)"
  fi

  if [ "$ckpt_ok" = "1" ]; then
    local mem_sz=$(du -sh "$mem_elf" | cut -f1)
    local pc=$(sed -n '3p' "$loadarch" | tr -d '[:space:]')
    echo "[$(date +%H:%M:%S)] DONE $w sp_$cluster — ${dt}s, pc=$pc, mem=$mem_sz" | tee -a "$LOG"
  else
    echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — ${dt}s, $fail_reason" | tee -a "$LOG"
  fi
}

export -f generate_one_checkpoint
export SPIKE OBJCOPY LD NM READELF SPIKE_DEVICES IMG_BASE CKPT_DIR INTERVAL ISA MEM_BASE MEM_SIZE LOG

# Build a flat list of (workload, cluster, interval) tuples and run in parallel
active=0
for w in "${WORKLOADS[@]}"; do
  sp_file=$SIMPOINT_DIR/$w.simpoints
  if [ ! -f "$sp_file" ]; then
    echo "[$(date +%H:%M:%S)] SKIP $w (no .simpoints file)" | tee -a "$LOG"
    continue
  fi
  while read interval cluster; do
    generate_one_checkpoint "$w" "$cluster" "$interval" </dev/null &
    ((active++))
    if [ $active -ge $JOBS ]; then
      wait -n 2>/dev/null
      ((active--))
    fi
  done < "$sp_file"
done
wait

echo "[$(date +%H:%M:%S)] All checkpoint jobs complete" | tee -a "$LOG"
echo
echo "=== Summary ==="
for w in "${WORKLOADS[@]}"; do
  sp_file=$SIMPOINT_DIR/$w.simpoints
  [ -f "$sp_file" ] || continue
  total=$(wc -l < "$sp_file")
  done_count=0
  while read interval cluster; do
    [ -f "$CKPT_DIR/$w/sp_$cluster/mem.elf" ] && [ -s "$CKPT_DIR/$w/sp_$cluster/mem.elf" ] && ((done_count++))
  done < "$sp_file"
  if [ "$done_count" -eq "$total" ]; then
    echo "OK    $w — $done_count/$total checkpoints"
  else
    echo "WARN  $w — $done_count/$total checkpoints ($(( total - done_count )) failed)"
  fi
done
