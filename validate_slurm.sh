#!/bin/bash
# validate_slurm.sh
# Submits ONE short sbatch job per SPEC2017 intspeed workload to smoke-test the
# checkpoint pipeline end-to-end. Uses --interval 10 (1 B insns) so every job
# finishes well under a 1-hour walltime.
#
# Writes:
#   $CKPT_DIR/<workload>/sp_v/{loadarch, mem.elf, slurm_status, ...}
#   $CKPT_DIR/logs/slurm-<workload>-<jobid>.{out,err}
#
# Usage:
#   ./validate_slurm.sh --partition P [--account A] [--time 01:00:00] [--mem 32G] [--dry-run]

set -u

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"

PARTITION=""
ACCOUNT=""
TIME="01:00:00"
MEM="32G"
DRY_RUN=0
CHIPYARD=/p/csd/jht9sy/chipyard
RT=$CHIPYARD/.conda-env/riscv-tools
IMG_BASE=/p/csd/jht9sy/checkpoints/images
SIMPOINT_DIR=/p/csd/jht9sy/checkpoints/simpoints
CKPT_DIR=/p/csd/jht9sy/checkpoints/intspeed-fullsystem-validation
VALIDATION_INTERVAL=10
VALIDATION_CLUSTER=v

while [[ $# -gt 0 ]]; do
  case $1 in
    --partition)    PARTITION=$2; shift 2 ;;
    --account)      ACCOUNT=$2;   shift 2 ;;
    --time)         TIME=$2;      shift 2 ;;
    --mem)          MEM=$2;       shift 2 ;;
    --ckpt-dir)     CKPT_DIR=$2;  shift 2 ;;
    --simpoint-dir) SIMPOINT_DIR=$2; shift 2 ;;
    --img-base)     IMG_BASE=$2;  shift 2 ;;
    --rt)           RT=$2;        shift 2 ;;
    --interval)     VALIDATION_INTERVAL=$2; shift 2 ;;
    --dry-run)      DRY_RUN=1;    shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$PARTITION" ] || { echo "ERROR: --partition required"; exit 1; }
[ -d "$SIMPOINT_DIR" ] || { echo "ERROR: $SIMPOINT_DIR does not exist"; exit 1; }

LOG_DIR=$CKPT_DIR/logs
mkdir -p "$LOG_DIR"

echo "=== Slurm validation submission ==="
echo "Partition:     $PARTITION"
echo "Account:       ${ACCOUNT:-<none>}"
echo "Walltime:      $TIME"
echo "Memory:        $MEM"
echo "Interval:      $VALIDATION_INTERVAL (= $(($VALIDATION_INTERVAL * 100)) M insns)"
echo "Cluster label: $VALIDATION_CLUSTER"
echo "Ckpt dir:      $CKPT_DIR"
echo "Log dir:       $LOG_DIR"
echo "Dry run:       $DRY_RUN"
echo ""

count=0
for sp_file in "$SIMPOINT_DIR"/*.simpoints; do
  [ -e "$sp_file" ] || continue
  w=$(basename "$sp_file" .simpoints)
  job_name="validate-$w"

  sbatch_args=(
    --job-name="$job_name"
    --partition="$PARTITION"
    --time="$TIME"
    --mem="$MEM"
    --cpus-per-task=1 --ntasks=1 --nodes=1
    --output="$LOG_DIR/slurm-$w-%j.out"
    --error="$LOG_DIR/slurm-$w-%j.err"
  )
  [ -n "$ACCOUNT" ] && sbatch_args+=(--account="$ACCOUNT")

  job_args=(
    --workload "$w"
    --cluster  "$VALIDATION_CLUSTER"
    --interval "$VALIDATION_INTERVAL"
    --ckpt-dir "$CKPT_DIR"
    --img-base "$IMG_BASE"
    --rt       "$RT"
  )

  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY  sbatch ${sbatch_args[*]} $SPECKLE_DIR/run_one_checkpoint_slurm.sh ${job_args[*]}"
  else
    job_id=$(sbatch "${sbatch_args[@]}" "$SPECKLE_DIR/run_one_checkpoint_slurm.sh" "${job_args[@]}" | awk '{print $NF}')
    echo "SUBMITTED $w  job=$job_id  log=$LOG_DIR/slurm-$w-$job_id.{out,err}"
  fi
  ((count++))
done

echo ""
echo "=== Summary: $count workload(s) $( [ "$DRY_RUN" = 1 ] && echo "would be submitted" || echo "submitted") ==="
