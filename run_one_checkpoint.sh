#!/bin/bash
# run_one_checkpoint.sh
#
# Runs a SINGLE spike checkpoint for one (workload, cluster, interval) tuple,
# locally — no Slurm. For cluster runs, use the pre-generated self-contained
# sbatch scripts under /p/csd/jht9sy/checkpoints/slurm-scripts/ instead.
#
# Usage:
#   ./run_one_checkpoint.sh \
#       --workload 602.gcc_s --cluster 3 --interval 18229 \
#       [--ckpt-dir /bigtemp2/...] [--img-base /path/to/images] [--isa rv64gc]
#
# Exit codes:
#   0  — checkpoint created successfully
#   1  — checkpoint generation failed (details in $outdir/status)
#   2  — checkpoint already exists (skipped)

set -u

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"

CHIPYARD=/p/csd/jht9sy/chipyard
source "$CHIPYARD/env.sh" 2>/dev/null || true

RT=$CHIPYARD/.conda-env/riscv-tools
SPIKE=$RT/bin/spike
NM=$RT/bin/riscv64-unknown-elf-nm
SPIKE_DEVICES=$RT/lib/libspikedevices.so

IMG_BASE=/p/csd/jht9sy/checkpoints/images
CKPT_DIR=/bigtemp2/jht9sy/checkpoints/ckpts
ISA=rv64gc
MEM_BASE=0x80000000
MEM_SIZE=0x800000000
INTERVAL=100000000

WORKLOAD=""
CLUSTER=""
INTERVAL_IDX=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --workload)   WORKLOAD=$2;    shift 2 ;;
    --cluster)    CLUSTER=$2;     shift 2 ;;
    --interval)   INTERVAL_IDX=$2; shift 2 ;;
    --ckpt-dir)   CKPT_DIR=$2;    shift 2 ;;
    --img-base)   IMG_BASE=$2;    shift 2 ;;
    --isa)        ISA=$2;         shift 2 ;;
    --rt)         RT=$2; SPIKE=$RT/bin/spike; NM=$RT/bin/riscv64-unknown-elf-nm; SPIKE_DEVICES=$RT/lib/libspikedevices.so; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$WORKLOAD" ]      || { echo "ERROR: --workload required" >&2; exit 1; }
[ -n "$CLUSTER" ]       || { echo "ERROR: --cluster required" >&2; exit 1; }
[ -n "$INTERVAL_IDX" ]  || { echo "ERROR: --interval required" >&2; exit 1; }
[ -x "$SPIKE" ]                            || { echo "ERROR: spike not found at $SPIKE" >&2; exit 1; }
[ -f "$SPECKLE_DIR/sparse_bin_to_elf.py" ] || { echo "ERROR: sparse_bin_to_elf.py not found in $SPECKLE_DIR" >&2; exit 1; }

w=$WORKLOAD
cluster=$CLUSTER
interval=$INTERVAL_IDX
insn_offset=$(( interval * INTERVAL ))
insn_hex=$(printf "0x%x" "$insn_offset")
outdir=$CKPT_DIR/$w/sp_$cluster

echo "[$(date +%H:%M:%S)] HOST=$(hostname) JOB=${SLURM_JOB_ID:-local} $w sp_$cluster interval=$interval insns=$insn_hex"

# Skip if already complete
if [ -f "$outdir/mem.elf" ] && [ -s "$outdir/mem.elf" ] && [ -f "$outdir/loadarch" ]; then
  lines=$(wc -l < "$outdir/loadarch")
  if [ "$lines" -eq 95 ]; then
    echo "SKIP $w sp_$cluster (complete, 95-line loadarch)"
    exit 2
  fi
fi

# Auto-detect nodisk vs disk image
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

rm -rf "$outdir"
mkdir -p "$outdir"

echo "$insn_hex"   > "$outdir/insn_offset.txt"
echo "$insn_offset" >> "$outdir/insn_offset.txt"

# Build spike debug command file
cmds=$outdir/cmds_tmp.txt
# spike's `rs` uses atoll() — decimal only, not hex
echo "rs $insn_offset" > "$cmds"
echo "dump" >> "$cmds"
echo "pc 0" >> "$cmds"
echo "priv 0" >> "$cmds"
echo "reg 0 fcsr" >> "$cmds"
# Vector CSR reads are REQUIRED — testchip_dtm.cc:216-220 expects exactly these
# 5 lines at this position. On a non-V spike they trap and produce
# "0xReceived trap:..." lines; std::stoull parses those as 0, which is correct
# reset state for vstart/vxsat/vxrm/vcsr/vtype.
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
# vreg: testchip_dtm.cc:255 checks for "VLEN=" on the line after GPRs.
# On non-V spike this traps, producing a non-VLEN line the driver skips.
echo "vreg 0" >> "$cmds"
echo "quit" >> "$cmds"

# Save the spike invocation for reproducibility
spikecmd=$outdir/spikecmd.sh
echo "$SPIKE -d --debug-cmd=$cmds $spike_extra_args --pmpregions=0 --isa=$ISA -p1 -m$MEM_BASE:$MEM_SIZE $bin" > "$spikecmd"
chmod +x "$spikecmd"

loadarch=$outdir/loadarch
echo 1 > "$loadarch"
t0=$(date +%s)

# Run spike from inside $outdir so `dump` writes mem.<addr>.bin there
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
  echo "FAIL $w sp_$cluster — no memory dump after ${dt}s (spike rc=$spike_rc)" | tee "$outdir/status"
  exit 1
fi

# Convert sparse binary dump to compact ELF (no 32 GB zero materialization)
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

# Validate
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
  echo "FAIL $w sp_$cluster — ${dt}s, $fail_reason (spike rc=$spike_rc)" | tee "$outdir/status"
  exit 1
fi

mem_sz=$(du -sh "$mem_elf" | cut -f1)
echo "DONE $w sp_$cluster — ${dt}s, pc=$pc, mem=$mem_sz (spike rc=$spike_rc)" | tee "$outdir/status"
exit 0
