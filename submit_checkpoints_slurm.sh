#!/bin/bash
# submit_checkpoints_slurm.sh
#
# Submits one Slurm job per (workload, simpoint) tuple to generate SPEC2017
# spike checkpoints in parallel. Each job calls run_one_checkpoint_slurm.sh.
#
# Usage:
#   ./submit_checkpoints_slurm.sh [options]
#
# Required Slurm options (no sensible defaults — you must specify these):
#   --partition PART      Slurm partition to submit to
#   --time HH:MM:SS       Walltime per job (longest job ~9 days; set 10-00:00:00
#                         if your cluster allows it, or use a checkpointable queue)
#   --mem MG              Memory per job in MB or GB (e.g. "16G")
#                         Most jobs fit in 8G; xz workloads need 16G+ due to
#                         ~5 GB memory footprint. Safer default: 32G.
#
# Optional:
#   --account ACCT        Slurm account / allocation
#   --constraint STR      Node feature constraint (e.g. "avx512" or "skylake")
#   --qos QOS             QOS name
#   --suite intspeed      Simpoint suite (default: intspeed)
#   --workloads "A B"     Only submit jobs for these workloads
#   --ckpt-dir DIR        Override default checkpoint output dir
#   --simpoint-dir DIR    Override default simpoint input dir
#   --img-base DIR        Override default image directory
#   --isa ISA             ISA string for spike (default: rv64gc)
#   --rt DIR              Path to riscv-tools prefix (default: chipyard .conda-env)
#   --dry-run             Print sbatch commands without submitting
#   --force               Re-submit even if checkpoint already exists
#   --pending-only        Skip workloads with in-flight Slurm jobs (by job name)
#   --max-submit N        Cap on total new submissions (safety limit, default 200)

set -u

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Paths that mirror generate_checkpoints_fullsystem.sh
RT=/home/jht9sy/work/chipyard/.conda-env/riscv-tools
IMG_BASE=/home/jht9sy/work/chipyard/software/firemarshal/images/firechip
SIMPOINT_ROOT=/data/akrish/riscv-simpoints
CKPT_ROOT=/data/akrish/checkpoints
INTERVAL=100000000
ISA=rv64gc
SUITE=intspeed

# Slurm options — must be set by caller
PARTITION=""
TIME=""
MEM=""
ACCOUNT=""
CONSTRAINT=""
QOS=""

# Script behaviour
DRY_RUN=0
FORCE=0
PENDING_ONLY=0
MAX_SUBMIT=200
CKPT_DIR_OVERRIDE=""
SIMPOINT_DIR_OVERRIDE=""
WORKLOADS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --partition)      PARTITION=$2;            shift 2 ;;
    --time)           TIME=$2;                 shift 2 ;;
    --mem)            MEM=$2;                  shift 2 ;;
    --account)        ACCOUNT=$2;              shift 2 ;;
    --constraint)     CONSTRAINT=$2;           shift 2 ;;
    --qos)            QOS=$2;                  shift 2 ;;
    --suite)          SUITE=$2;                shift 2 ;;
    --workloads)      read -r -a WORKLOADS <<< "$2"; shift 2 ;;
    --ckpt-dir)       CKPT_DIR_OVERRIDE=$2;    shift 2 ;;
    --simpoint-dir)   SIMPOINT_DIR_OVERRIDE=$2; shift 2 ;;
    --img-base)       IMG_BASE=$2;             shift 2 ;;
    --isa)            ISA=$2;                  shift 2 ;;
    --rt)             RT=$2;                   shift 2 ;;
    --dry-run)        DRY_RUN=1;               shift ;;
    --force)          FORCE=1;                 shift ;;
    --pending-only)   PENDING_ONLY=1;          shift ;;
    --max-submit)     MAX_SUBMIT=$2;           shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Validate required Slurm options
errors=0
[ -n "$PARTITION" ] || { echo "ERROR: --partition required" >&2; ((errors++)); }
[ -n "$TIME" ]      || { echo "ERROR: --time required (e.g. --time 10-00:00:00)" >&2; ((errors++)); }
[ -n "$MEM" ]       || { echo "ERROR: --mem required (e.g. --mem 32G)" >&2; ((errors++)); }
[ "$errors" -gt 0 ] && exit 1

SIMPOINT_DIR=${SIMPOINT_DIR_OVERRIDE:-$SIMPOINT_ROOT/${SUITE}-fullsystem}
CKPT_DIR=${CKPT_DIR_OVERRIDE:-$CKPT_ROOT/${SUITE}-fullsystem}

[ -d "$SIMPOINT_DIR" ] || { echo "ERROR: $SIMPOINT_DIR does not exist"; exit 1; }

# Discover workloads
if [ ${#WORKLOADS[@]} -eq 0 ]; then
  for sp_file in "$SIMPOINT_DIR"/*.simpoints; do
    [ -e "$sp_file" ] || continue
    WORKLOADS+=("$(basename "$sp_file" .simpoints)")
  done
fi
[ ${#WORKLOADS[@]} -gt 0 ] || { echo "ERROR: no simpoints found in $SIMPOINT_DIR"; exit 1; }

echo "=== Slurm checkpoint submission ==="
echo "Suite:       $SUITE"
echo "Workloads:   ${#WORKLOADS[@]}"
echo "Partition:   $PARTITION"
echo "Time:        $TIME"
echo "Mem:         $MEM"
echo "Ckpt dir:    $CKPT_DIR"
echo "Dry run:     $DRY_RUN"
echo "Force:       $FORCE"
echo ""

submitted=0
skipped_done=0
skipped_running=0

for w in "${WORKLOADS[@]}"; do
  sp_file=$SIMPOINT_DIR/$w.simpoints
  if [ ! -f "$sp_file" ]; then
    echo "SKIP $w (no .simpoints file)"
    continue
  fi

  while read interval cluster; do
    outdir=$CKPT_DIR/$w/sp_$cluster
    job_name="ckpt-${w}-${cluster}"

    # Skip complete checkpoints unless --force
    if [ "$FORCE" = "0" ] && \
       [ -f "$outdir/mem.elf" ] && [ -s "$outdir/mem.elf" ] && \
       [ -f "$outdir/loadarch" ] && [ "$(wc -l < "$outdir/loadarch")" -eq 95 ]; then
      ((skipped_done++))
      continue
    fi

    # Skip if a matching Slurm job is already queued/running (by job name)
    if [ "$PENDING_ONLY" = "1" ] && squeue -h -n "$job_name" -o "%i" 2>/dev/null | grep -q .; then
      echo "SKIP $w sp_$cluster (Slurm job $job_name already queued)"
      ((skipped_running++))
      continue
    fi

    if [ "$submitted" -ge "$MAX_SUBMIT" ]; then
      echo "MAX_SUBMIT ($MAX_SUBMIT) reached — stopping early. Re-run to submit more."
      break 2
    fi

    # Build sbatch command
    mkdir -p "$outdir"

    sbatch_args=(
      --job-name="$job_name"
      --partition="$PARTITION"
      --time="$TIME"
      --mem="$MEM"
      --cpus-per-task=1
      --ntasks=1
      --nodes=1
      --output="$outdir/slurm-%j.out"
      --error="$outdir/slurm-%j.err"
    )
    [ -n "$ACCOUNT" ]    && sbatch_args+=(--account="$ACCOUNT")
    [ -n "$CONSTRAINT" ] && sbatch_args+=(--constraint="$CONSTRAINT")
    [ -n "$QOS" ]        && sbatch_args+=(--qos="$QOS")

    job_args=(
      --workload "$w"
      --cluster  "$cluster"
      --interval "$interval"
      --ckpt-dir "$CKPT_DIR"
      --img-base "$IMG_BASE"
      --isa      "$ISA"
      --rt       "$RT"
    )

    if [ "$DRY_RUN" = "1" ]; then
      echo "DRY  sbatch ${sbatch_args[*]} $SPECKLE_DIR/run_one_checkpoint_slurm.sh ${job_args[*]}"
    else
      job_id=$(sbatch "${sbatch_args[@]}" \
                 "$SPECKLE_DIR/run_one_checkpoint_slurm.sh" \
                 "${job_args[@]}" \
                 | awk '{print $NF}')
      echo "SUBMITTED $w sp_$cluster job=$job_id"
    fi
    ((submitted++))

  done < "$sp_file"
done

echo ""
echo "=== Summary ==="
echo "Submitted: $submitted"
echo "Skipped (done):    $skipped_done"
echo "Skipped (running): $skipped_running"
if [ "$DRY_RUN" = "1" ]; then
  echo "(dry run — nothing actually submitted)"
fi
