#!/bin/bash
# validate_checkpoints_fullsystem.sh
#
# Sanity check for spike checkpoint generation. For each workload, picks
# the SMALLEST simpoint (fewest instructions to fast-forward), runs spike
# to generate that one checkpoint, then validates the output. This mirrors
# validate_qemu_system.sh — it actually runs the tool, not just checks files.
#
# Outputs go to a dedicated sanity directory so real checkpoint runs aren't
# touched.
#
# Usage:
#   ./validate_checkpoints_fullsystem.sh                    # all workloads
#   ./validate_checkpoints_fullsystem.sh --jobs 4
#   ./validate_checkpoints_fullsystem.sh --workloads "648.exchange2_s"

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
CKPT_DIR=/data/akrish/checkpoints/sanity/intspeed-fullsystem
INTERVAL=100000000
ISA=rv64gc
MEM_BASE=0x80000000
MEM_SIZE=0x800000000
JOBS=4
SUITE=intspeed
SIMPOINT_DIR_OVERRIDE=""
WORKLOADS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --suite)         SUITE=$2;                  shift 2 ;;
    --workloads)     read -r -a WORKLOADS <<< "$2"; shift 2 ;;
    --jobs)          JOBS=$2;                   shift 2 ;;
    --ckpt-dir)      CKPT_DIR=$2;               shift 2 ;;
    --simpoint-dir)  SIMPOINT_DIR_OVERRIDE=$2;  shift 2 ;;
    --img-base)      IMG_BASE=$2;               shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -x "$SPIKE" ]   || { echo "ERROR: spike not found at $SPIKE"; exit 1; }
[ -x "$OBJCOPY" ] || { echo "ERROR: objcopy not found at $OBJCOPY"; exit 1; }
[ -x "$LD" ]      || { echo "ERROR: ld not found at $LD"; exit 1; }

SIMPOINT_DIR=${SIMPOINT_DIR_OVERRIDE:-$SIMPOINT_ROOT/${SUITE}-fullsystem}

if [ ! -d "$SIMPOINT_DIR" ]; then
  echo "ERROR: $SIMPOINT_DIR does not exist — run run_simpoint_fullsystem.sh first"
  exit 1
fi

# Discover workloads from simpoint files if not specified
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
LOG=$CKPT_DIR/sanity.log
echo "[$(date +%H:%M:%S)] Sanity Suite=$SUITE Workloads=${#WORKLOADS[@]} Jobs=$JOBS ISA=$ISA" | tee "$LOG"
printf '  %s\n' "${WORKLOADS[@]}" | tee -a "$LOG"

# Parses a loadarch file and returns a status string.
# Checks for: trap messages, kernel panic, reset-vector PC, empty/missing data.
check_loadarch() {
  local loadarch=$1

  if [ ! -f "$loadarch" ] || [ ! -s "$loadarch" ]; then
    echo "EMPTY_LOADARCH"
    return
  fi

  # Check for error strings spike dumps to stderr (which we redirect into loadarch)
  if grep -q 'Kernel panic' "$loadarch" 2>/dev/null; then
    echo "KERNEL_PANIC"
    return
  fi

  # Line 3 is the PC (format: "1\n:\n<pc>\n<priv>\n...")
  local pc=$(sed -n '3p' "$loadarch" | tr -d '[:space:]')

  if [ "$pc" = "0x0000000000001000" ]; then
    echo "RESET_VECTOR_PC"
    return
  fi
  if grep -q 'trap_illegal_instruction\|Received trap' "$loadarch" 2>/dev/null; then
    echo "TRAP_ILLEGAL_INSN"
    return
  fi
  if [ -z "$pc" ] || [ "$pc" = "0x0000000000000000" ]; then
    echo "ZERO_PC"
    return
  fi

  echo "OK:$pc"
}

validate_one() {
  local w=$1
  local sp_file=$SIMPOINT_DIR/$w.simpoints

  if [ ! -f "$sp_file" ]; then
    echo "[$(date +%H:%M:%S)] SKIP $w (no .simpoints file)" | tee -a "$LOG"
    return
  fi

  # Pick the smallest simpoint interval (fastest to reach)
  local smallest_line=$(sort -n "$sp_file" | head -1)
  local interval=$(echo "$smallest_line" | awk '{print $1}')
  local cluster=$(echo "$smallest_line" | awk '{print $2}')
  local insn_offset=$(( interval * INTERVAL ))
  local insn_hex=$(printf "0x%x" "$insn_offset")

  # Auto-detect nodisk vs disk
  local bin spike_extra_args mode
  if [ -f "$IMG_BASE/$w/$w-bin-nodisk" ]; then
    bin=$IMG_BASE/$w/$w-bin-nodisk
    spike_extra_args=""
    mode=nodisk
  elif [ -f "$IMG_BASE/$w/$w-bin" ] && [ -f "$IMG_BASE/$w/$w.img" ]; then
    bin=$IMG_BASE/$w/$w-bin
    spike_extra_args="--extlib=$SPIKE_DEVICES --device=iceblk,img=$IMG_BASE/$w/$w.img"
    mode=disk
  else
    echo "[$(date +%H:%M:%S)] FAIL $w (no image found)" | tee -a "$LOG"
    return
  fi

  local outdir=$CKPT_DIR/$w/sp_$cluster
  rm -rf "$outdir"
  mkdir -p "$outdir"

  # Generate spike debug commands
  local cmds=$outdir/cmds_tmp.txt
  # spike's `rs` uses atoll() which only parses DECIMAL, not hex
  echo "rs $insn_offset" > "$cmds"
  echo "dump" >> "$cmds"
  echo "pc 0" >> "$cmds"
  echo "priv 0" >> "$cmds"
  echo "reg 0 fcsr" >> "$cmds"
  # Vector CSRs required by testchip_dtm.cc loadarch parser (see generate script)
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
  echo "vreg 0" >> "$cmds"
  echo "quit" >> "$cmds"

  echo "[$(date +%H:%M:%S)] START $w sp_$cluster ($mode, interval=$interval, insns=$insn_hex)" | tee -a "$LOG"
  local t0=$(date +%s)

  # Run spike
  local loadarch=$outdir/loadarch
  echo 1 > "$loadarch"
  $SPIKE -d --debug-cmd="$cmds" \
    $spike_extra_args \
    --pmpregions=0 --isa=$ISA -p1 \
    -m$MEM_BASE:$MEM_SIZE \
    "$bin" 2>> "$loadarch"
  local spike_rc=$?
  local dt=$(( $(date +%s) - t0 ))

  # Convert memory dump to ELF
  local mem_dump="mem.$MEM_BASE.bin"
  if [ -f "$mem_dump" ]; then
    local raw_elf=$outdir/raw.elf
    local mem_elf=$outdir/mem.elf
    $OBJCOPY -I binary -O elf64-littleriscv "$mem_dump" "$raw_elf" 2>/dev/null
    local tohost fromhost
    tohost=$($NM "$bin" 2>/dev/null | awk '/ tohost$/ {print $1}' | head -1)
    fromhost=$($NM "$bin" 2>/dev/null | awk '/ fromhost$/ {print $1}' | head -1)
    if [ -n "$tohost" ] && [ -n "$fromhost" ]; then
      $LD -Tdata=$MEM_BASE -nmagic --defsym "tohost=0x$tohost" --defsym "fromhost=0x$fromhost" -o "$mem_elf" "$raw_elf" 2>/dev/null
    else
      $LD -Tdata=$MEM_BASE -nmagic -o "$mem_elf" "$raw_elf" 2>/dev/null
    fi
    rm -f "$raw_elf" "$mem_dump"
  fi

  # Validate the loadarch
  local status=$(check_loadarch "$loadarch")
  local mem_elf=$outdir/mem.elf
  local mem_ok=0
  [ -f "$mem_elf" ] && [ -s "$mem_elf" ] && $READELF -h "$mem_elf" > /dev/null 2>&1 && mem_ok=1

  case "$status" in
    OK:*)
      local pc=${status#OK:}
      if [ "$mem_ok" = "1" ]; then
        local mem_sz=$(du -sh "$mem_elf" | cut -f1)
        echo "[$(date +%H:%M:%S)] PASS $w sp_$cluster — ${dt}s, pc=$pc, mem=$mem_sz (spike rc=$spike_rc)" | tee -a "$LOG"
      else
        echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — loadarch OK (pc=$pc) but mem.elf missing/invalid (spike rc=$spike_rc, ${dt}s)" | tee -a "$LOG"
      fi
      ;;
    EMPTY_LOADARCH)
      echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — empty loadarch (spike rc=$spike_rc, ${dt}s)" | tee -a "$LOG"
      ;;
    TRAP_ILLEGAL_INSN)
      echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — illegal instruction trap in loadarch (spike rc=$spike_rc, ${dt}s)" | tee -a "$LOG"
      ;;
    KERNEL_PANIC)
      echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — kernel panic in loadarch (spike rc=$spike_rc, ${dt}s)" | tee -a "$LOG"
      ;;
    RECEIVED_TRAP)
      echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — trap received in loadarch (spike rc=$spike_rc, ${dt}s)" | tee -a "$LOG"
      ;;
    RESET_VECTOR_PC)
      echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — PC stuck at reset vector 0x1000 (spike rc=$spike_rc, ${dt}s)" | tee -a "$LOG"
      ;;
    ZERO_PC)
      echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — PC is zero (spike rc=$spike_rc, ${dt}s)" | tee -a "$LOG"
      ;;
    *)
      echo "[$(date +%H:%M:%S)] FAIL $w sp_$cluster — unknown status: $status (spike rc=$spike_rc, ${dt}s)" | tee -a "$LOG"
      ;;
  esac
}

export -f validate_one check_loadarch
export SPIKE OBJCOPY LD NM READELF SPIKE_DEVICES IMG_BASE SIMPOINT_DIR CKPT_DIR INTERVAL ISA MEM_BASE MEM_SIZE LOG

active=0
for w in "${WORKLOADS[@]}"; do
  validate_one "$w" &
  ((active++))
  if [ $active -ge $JOBS ]; then
    wait -n 2>/dev/null || wait
    ((active--))
  fi
done
wait

echo "[$(date +%H:%M:%S)] Sanity complete" | tee -a "$LOG"
echo
echo "=== Summary ==="
for w in "${WORKLOADS[@]}"; do
  sp_file=$SIMPOINT_DIR/$w.simpoints
  [ -f "$sp_file" ] || continue
  smallest_interval=$(sort -n "$sp_file" | head -1 | awk '{print $1}')
  smallest_cluster=$(sort -n "$sp_file" | head -1 | awk '{print $2}')
  dir=$CKPT_DIR/$w/sp_$smallest_cluster
  if [ -f "$dir/mem.elf" ] && [ -s "$dir/mem.elf" ]; then
    status=$(check_loadarch "$dir/loadarch")
    case "$status" in
      OK:*) echo "OK    $w (sp_$smallest_cluster, interval=$smallest_interval)" ;;
      *)    echo "FAIL  $w (sp_$smallest_cluster: $status)" ;;
    esac
  else
    echo "FAIL  $w (sp_$smallest_cluster: missing or incomplete)"
  fi
done
