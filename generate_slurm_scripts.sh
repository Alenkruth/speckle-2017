#!/bin/bash
# generate_slurm_scripts.sh
#
# Pre-materializes self-contained sbatch scripts for the SPEC2017 intspeed
# checkpoint pipeline — one .sbatch file per (workload, simpoint) tuple from
# the .simpoints files. Each generated .sbatch inlines the entire spike
# invocation + sparse_bin_to_elf.py conversion, so there's no indirection —
# just submit the file with `sbatch` and it self-describes.
#
# Output layout:
#   /p/csd/jht9sy/checkpoints/slurm-scripts/ckpt-<workload>-sp<N>.sbatch
#   /bigtemp2/jht9sy/checkpoints/intspeed-fullsystem/{<w>/sp_<N>/,logs/}
#
# Usage:
#   ./generate_slurm_scripts.sh [--force]
#     --force   overwrite existing .sbatch files

set -eu

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"
SIMPOINT_DIR=/p/csd/jht9sy/checkpoints/simpoints
IMG_BASE=/p/csd/jht9sy/checkpoints/images
RT=/p/csd/jht9sy/chipyard/.conda-env/riscv-tools

SCRIPT_DIR=/p/csd/jht9sy/checkpoints/slurm-scripts
CKPT_DIR=/bigtemp2/jht9sy/checkpoints/intspeed-fullsystem
LOG_DIR=$CKPT_DIR/logs
PARTITION=cpu
TIME=4-00:00:00
MEM=32G

MAIL_USER=jht9sy@virginia.edu
MAIL_TYPE=begin,end,fail

mkdir -p "$SCRIPT_DIR" "$LOG_DIR"

emit_sbatch() {
  # $1 = output .sbatch path
  # $2 = job name
  # $3 = partition, $4 = time, $5 = mem
  # $6 = log dir (for --output/--error)
  # $7 = workload, $8 = cluster label, $9 = interval, ${10} = ckpt dir
  local out=$1 jobname=$2 part=$3 time=$4 mem=$5 logdir=$6
  local workload=$7 cluster=$8 interval=$9 ckptdir=${10}

  if [ "$FORCE" = "0" ] && [ -e "$out" ]; then
    echo "SKIP (exists) $out"
    return
  fi

  # Header: expanded at generation time — bakes job-specific values in.
  cat > "$out" <<HEADER
#!/bin/bash
#SBATCH --job-name=$jobname
#SBATCH --partition=$part
#SBATCH --time=$time
#SBATCH --mem=$mem
#SBATCH --cpus-per-task=1
#SBATCH --ntasks=1
#SBATCH --nodes=1
#SBATCH --output=$logdir/$jobname-%j.out
#SBATCH --error=$logdir/$jobname-%j.err
#SBATCH --mail-user=$MAIL_USER
#SBATCH --mail-type=$MAIL_TYPE

set -u

# Job-specific values (baked in by generate_slurm_scripts.sh)
WORKLOAD=$workload
CLUSTER=$cluster
INTERVAL_IDX=$interval
CKPT_DIR=$ckptdir

HEADER

  # Body: single-quoted heredoc — NO expansion at generation time.
  # Everything below runs at sbatch-job runtime.
  cat >> "$out" <<'BODY'
# ---- Toolchain + paths (identical for every checkpoint job) -----------------
SPECKLE_DIR=/p/csd/jht9sy/speckle-2017
CHIPYARD=/p/csd/jht9sy/chipyard
source "$CHIPYARD/env.sh" 2>/dev/null || true

RT=$CHIPYARD/.conda-env/riscv-tools
SPIKE=$RT/bin/spike
NM=$RT/bin/riscv64-unknown-elf-nm
SPIKE_DEVICES=$RT/lib/libspikedevices.so

IMG_BASE=/p/csd/jht9sy/checkpoints/images
ISA=rv64gc
MEM_BASE=0x80000000
MEM_SIZE=0x800000000
INTERVAL=100000000

[ -x "$SPIKE" ]                            || { echo "ERROR: spike not found at $SPIKE"; exit 1; }
[ -f "$SPECKLE_DIR/sparse_bin_to_elf.py" ] || { echo "ERROR: sparse_bin_to_elf.py missing in $SPECKLE_DIR"; exit 1; }

# ---- Compute per-job offsets ------------------------------------------------
w=$WORKLOAD
cluster=$CLUSTER
interval=$INTERVAL_IDX
insn_offset=$(( interval * INTERVAL ))
insn_hex=$(printf "0x%x" "$insn_offset")
outdir=$CKPT_DIR/$w/sp_$cluster

echo "[$(date +%H:%M:%S)] HOST=$(hostname) JOB=${SLURM_JOB_ID:-local} $w sp_$cluster interval=$interval insns=$insn_hex"

# ---- Idempotency: skip if a complete checkpoint already exists --------------
if [ -f "$outdir/mem.elf" ] && [ -s "$outdir/mem.elf" ] && [ -f "$outdir/loadarch" ]; then
  if [ "$(wc -l < "$outdir/loadarch")" -eq 95 ]; then
    echo "SKIP $w sp_$cluster (already complete: 95-line loadarch + non-empty mem.elf)"
    exit 2
  fi
fi

# ---- Detect nodisk vs disk-mode image ---------------------------------------
if [ -f "$IMG_BASE/$w/$w-bin-nodisk" ]; then
  bin=$IMG_BASE/$w/$w-bin-nodisk
  spike_extra_args=""
elif [ -f "$IMG_BASE/$w/$w-bin" ] && [ -f "$IMG_BASE/$w/$w.img" ]; then
  bin=$IMG_BASE/$w/$w-bin
  spike_extra_args="--extlib=$SPIKE_DEVICES --device=iceblk,img=$IMG_BASE/$w/$w.img"
else
  echo "FAIL $w sp_$cluster (no image found under $IMG_BASE/$w/)" >&2
  exit 1
fi

# ---- Fresh output directory -------------------------------------------------
rm -rf "$outdir"
mkdir -p "$outdir"

echo "$insn_hex"    > "$outdir/insn_offset.txt"
echo "$insn_offset" >> "$outdir/insn_offset.txt"

# ---- Build spike debug-command file ----------------------------------------
# testchip_dtm.cc parses the resulting loadarch at fixed line offsets (95 lines
# total). DO NOT reorder. spike's `rs` takes a DECIMAL count (atoll), not hex.
cmds=$outdir/cmds_tmp.txt
cat > "$cmds" <<CMDS
rs $insn_offset
dump
pc 0
priv 0
reg 0 fcsr
reg 0 vstart
reg 0 vxsat
reg 0 vxrm
reg 0 vcsr
reg 0 vtype
reg 0 stvec
reg 0 sscratch
reg 0 sepc
reg 0 scause
reg 0 stval
reg 0 satp
reg 0 mstatus
reg 0 medeleg
reg 0 mideleg
reg 0 mie
reg 0 mtvec
reg 0 mscratch
reg 0 mepc
reg 0 mcause
reg 0 mtval
reg 0 mip
reg 0 mcycle
reg 0 minstret
mtime
mtimecmp 0
CMDS
for fr in $(seq 0 31); do echo "freg 0 $fr" >> "$cmds"; done
for xr in $(seq 0 31); do echo "reg 0 $xr"  >> "$cmds"; done
echo "vreg 0" >> "$cmds"
echo "quit"   >> "$cmds"

# ---- Save the spike invocation for reproducibility --------------------------
spikecmd=$outdir/spikecmd.sh
echo "$SPIKE -d --debug-cmd=$cmds $spike_extra_args --pmpregions=0 --isa=$ISA -p1 -m$MEM_BASE:$MEM_SIZE $bin" > "$spikecmd"
chmod +x "$spikecmd"

# ---- Run spike --------------------------------------------------------------
loadarch=$outdir/loadarch
echo 1 > "$loadarch"
t0=$(date +%s)

# cd into $outdir so spike's `dump` writes mem.<addr>.bin there
( cd "$outdir" && \
  $SPIKE -d --debug-cmd="$cmds" \
    $spike_extra_args \
    --pmpregions=0 --isa=$ISA -p1 \
    -m$MEM_BASE:$MEM_SIZE \
    "$bin" 2>> "$loadarch" )
spike_rc=$?
dt=$(( $(date +%s) - t0 ))

mem_dump="$outdir/mem.$MEM_BASE.bin"
if [ ! -f "$mem_dump" ]; then
  echo "FAIL $w sp_$cluster — no memory dump after ${dt}s (spike rc=$spike_rc)" | tee "$outdir/slurm_status"
  exit 1
fi

# ---- Convert sparse dump → compact ELF --------------------------------------
# sparse_bin_to_elf.py uses SEEK_DATA/SEEK_HOLE to find non-zero regions and
# emits one PT_LOAD per region — final ELF ≈ workload footprint, not 32 GB.
mem_elf=$outdir/mem.elf
tohost=$($NM "$bin"   2>/dev/null | awk '/ tohost$/   {print $1}' | head -1)
fromhost=$($NM "$bin" 2>/dev/null | awk '/ fromhost$/ {print $1}' | head -1)

sparse_args=()
[ -n "$tohost" ]   && sparse_args+=(--tohost   "0x$tohost")
[ -n "$fromhost" ] && sparse_args+=(--fromhost "0x$fromhost")

python3 "$SPECKLE_DIR/sparse_bin_to_elf.py" \
    "$mem_dump" "$mem_elf" "$MEM_BASE" \
    "${sparse_args[@]}" \
    --delete-input

# ---- Validate the result ----------------------------------------------------
fail_reason=""
if [ ! -f "$mem_elf" ] || [ ! -s "$mem_elf" ]; then
  fail_reason="mem.elf missing or empty"
elif grep -q 'Kernel panic' "$loadarch" 2>/dev/null; then
  fail_reason="kernel panic in loadarch"
fi

nlines=$(wc -l < "$loadarch")
pc=$(sed -n '3p' "$loadarch" | tr -d '[:space:]')
if [ "$pc" = "0x0000000000001000" ] || [ -z "$pc" ]; then
  fail_reason="PC stuck at reset vector ($pc)"
elif sed -n '11,94p' "$loadarch" 2>/dev/null | grep -q 'trap_illegal_instruction\|Received trap'; then
  # Lines 6-10 (vector CSRs) and line 95 (vreg) are expected to contain
  # "Received trap" on non-V spike — only flag traps on lines 11-94.
  fail_reason="trap during fast-forward (in CSR/FPR/GPR region)"
elif [ "$nlines" -ne 95 ]; then
  fail_reason="wrong loadarch line count: got $nlines, expected 95"
fi

if [ -n "$fail_reason" ]; then
  echo "FAIL $w sp_$cluster — ${dt}s, $fail_reason (spike rc=$spike_rc)" | tee "$outdir/slurm_status"
  exit 1
fi

mem_sz=$(du -sh "$mem_elf" | cut -f1)
echo "DONE $w sp_$cluster — ${dt}s, pc=$pc, mem=$mem_sz (spike rc=$spike_rc)" | tee "$outdir/slurm_status"
exit 0
BODY

  chmod +x "$out"
  echo "WROTE $out"
}

echo "=== Generating checkpoint sbatch scripts ==="
for sp_file in "$SIMPOINT_DIR"/*.simpoints; do
  [ -e "$sp_file" ] || continue
  w=$(basename "$sp_file" .simpoints)
  while read interval cluster; do
    [ -n "${interval:-}" ] || continue
    [ -n "${cluster:-}" ]  || continue
    emit_sbatch \
      "$SCRIPT_DIR/ckpt-$w-sp$cluster.sbatch" \
      "ckpt-$w-sp$cluster" \
      "$PARTITION" "$TIME" "$MEM" \
      "$LOG_DIR" \
      "$w" "$cluster" "$interval" "$CKPT_DIR"
  done < "$sp_file"
done

echo ""
echo "=== Summary ==="
echo "Scripts: $SCRIPT_DIR/  ($(ls "$SCRIPT_DIR"/*.sbatch 2>/dev/null | wc -l) files)"
echo "Logs:    $LOG_DIR"
echo "Ckpts:   $CKPT_DIR"
