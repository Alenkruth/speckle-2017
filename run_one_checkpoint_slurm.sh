#!/bin/bash
# run_one_checkpoint_slurm.sh
#
# Runs a SINGLE spike checkpoint for one (workload, cluster, interval) tuple.
# Designed to be submitted as a Slurm job via submit_checkpoints_slurm.sh,
# but also runnable standalone for testing.
#
# Usage:
#   ./run_one_checkpoint_slurm.sh \
#       --workload 602.gcc_s --cluster 3 --interval 18229 \
#       [--ckpt-dir /data/...] [--img-base /path/to/images] [--isa rv64gc]
#
# Exit codes:
#   0  — checkpoint created successfully
#   1  — checkpoint generation failed (details in $outdir/slurm_status)
#   2  — checkpoint already exists (skipped)

set -u

RT=/home/jht9sy/work/chipyard/.conda-env/riscv-tools
SPIKE=$RT/bin/spike
OBJCOPY=$RT/bin/riscv64-unknown-elf-objcopy
LD=$RT/bin/riscv64-unknown-elf-ld
NM=$RT/bin/riscv64-unknown-elf-nm
SPIKE_DEVICES=$RT/lib/libspikedevices.so

IMG_BASE=/home/jht9sy/work/chipyard/software/firemarshal/images/firechip
CKPT_DIR=/data/akrish/checkpoints/intspeed-fullsystem
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
    --rt)         RT=$2; SPIKE=$RT/bin/spike; OBJCOPY=$RT/bin/riscv64-unknown-elf-objcopy; LD=$RT/bin/riscv64-unknown-elf-ld; NM=$RT/bin/riscv64-unknown-elf-nm; SPIKE_DEVICES=$RT/lib/libspikedevices.so; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$WORKLOAD" ]      || { echo "ERROR: --workload required" >&2; exit 1; }
[ -n "$CLUSTER" ]       || { echo "ERROR: --cluster required" >&2; exit 1; }
[ -n "$INTERVAL_IDX" ]  || { echo "ERROR: --interval required" >&2; exit 1; }
[ -x "$SPIKE" ]         || { echo "ERROR: spike not found at $SPIKE" >&2; exit 1; }
[ -x "$OBJCOPY" ]       || { echo "ERROR: objcopy not found at $OBJCOPY" >&2; exit 1; }
[ -x "$LD" ]            || { echo "ERROR: ld not found at $LD" >&2; exit 1; }

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
  echo "FAIL $w sp_$cluster — no memory dump after ${dt}s (spike rc=$spike_rc)" | tee "$outdir/slurm_status"
  exit 1
fi

# Convert raw binary dump to ELF
raw_elf=$outdir/raw.elf
mem_elf=$outdir/mem.elf
$OBJCOPY -I binary -O elf64-littleriscv "$mem_dump" "$raw_elf"

tohost=$($NM "$bin" 2>/dev/null | awk '/ tohost$/ {print $1}' | head -1)
fromhost=$($NM "$bin" 2>/dev/null | awk '/ fromhost$/ {print $1}' | head -1)
if [ -n "$tohost" ] && [ -n "$fromhost" ]; then
  $LD -Tdata=$MEM_BASE -nmagic --defsym "tohost=0x$tohost" --defsym "fromhost=0x$fromhost" -o "$mem_elf" "$raw_elf"
else
  $LD -Tdata=$MEM_BASE -nmagic -o "$mem_elf" "$raw_elf"
fi
rm -f "$raw_elf" "$mem_dump"

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
  echo "FAIL $w sp_$cluster — ${dt}s, $fail_reason (spike rc=$spike_rc)" | tee "$outdir/slurm_status"
  exit 1
fi

mem_sz=$(du -sh "$mem_elf" | cut -f1)
echo "DONE $w sp_$cluster — ${dt}s, pc=$pc, mem=$mem_sz (spike rc=$spike_rc)" | tee "$outdir/slurm_status"
exit 0
