#!/bin/bash
# validate_simpoint_fullsystem.sh
#
# Sanity check: runs SimPoint clustering on each full-system BBV with a
# smaller maxK, writing outputs to a dedicated sanity directory so real
# simpoint runs aren't touched. Reports per-bench pass/fail and weight sums.
#
# Sister to validate_simpoint.sh (user-mode flow).
#
# Usage:
#   ./validate_simpoint_fullsystem.sh                  # intspeed defaults
#   ./validate_simpoint_fullsystem.sh --suite fpspeed
#   ./validate_simpoint_fullsystem.sh --jobs 8 --maxk 8
#   ./validate_simpoint_fullsystem.sh --bbv-dir /path/to/bbvs

set -u

SIMPOINT=/home/jht9sy/work/simpoint/bin/simpoint
BBV_ROOT=/data/akrish/riscv-spec2017-bbvs
SIMPOINT_ROOT=/data/akrish/riscv-simpoints/sanity
JOBS=10
MAXK=8
SUITE=intspeed
BBV_DIR_OVERRIDE=""
SIMPOINT_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --suite)         SUITE=$2;                  shift 2 ;;
        --jobs)          JOBS=$2;                   shift 2 ;;
        --maxk)          MAXK=$2;                   shift 2 ;;
        --bbv-dir)       BBV_DIR_OVERRIDE=$2;       shift 2 ;;
        --simpoint-dir)  SIMPOINT_DIR_OVERRIDE=$2;  shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# By default consume the sanity full-system BBVs produced by
# validate_qemu_system.sh, which writes to /bbv-sanity/<suite>-fullsystem/.
# If the user has full BBVs in /<suite>-fullsystem/ they can point at
# those via --bbv-dir.
BBV_DIR=${BBV_DIR_OVERRIDE:-$BBV_ROOT/bbv-sanity/${SUITE}-fullsystem}
SIMPOINT_DIR=${SIMPOINT_DIR_OVERRIDE:-$SIMPOINT_ROOT/${SUITE}-fullsystem}

if [ ! -d "$BBV_DIR" ]; then
    echo "ERROR: $BBV_DIR does not exist — run validate_qemu_system.sh --suite $SUITE first"
    exit 1
fi
if [ ! -x "$SIMPOINT" ]; then
    echo "ERROR: SimPoint binary not found at $SIMPOINT"
    exit 1
fi

shopt -s nullglob
BBV_FILES=( "$BBV_DIR"/*.bb.0.bb )
shopt -u nullglob
if [ ${#BBV_FILES[@]} -eq 0 ]; then
    echo "ERROR: no .bb.0.bb files found in $BBV_DIR"
    exit 1
fi

mkdir -p "$SIMPOINT_DIR"
LOG=$SIMPOINT_DIR/sanity.log
echo "[$(date +%H:%M:%S)] Suite=$SUITE BBV_DIR=$BBV_DIR Workloads=${#BBV_FILES[@]} Jobs=$JOBS MaxK=$MAXK" | tee "$LOG"

run_simpoint() {
    local bbv=$1
    local bench=$(basename "$bbv" .bb.0.bb)
    local outbase=$SIMPOINT_DIR/$bench

    echo "[$(date +%H:%M:%S)] START $bench" | tee -a "$LOG"
    local t0=$(date +%s)

    "$SIMPOINT" \
        -loadFVFile "$bbv" \
        -maxK "$MAXK" \
        -saveSimpoints "$outbase.simpoints" \
        -saveSimpointWeights "$outbase.weights" \
        -saveLabels "$outbase.labels" \
        > "$outbase.simpoint.log" 2>&1

    local exit_code=$?
    local dt=$(( $(date +%s) - t0 ))
    if [ $exit_code -eq 0 ] && [ -s "$outbase.simpoints" ]; then
        local k=$(wc -l < "$outbase.simpoints")
        echo "[$(date +%H:%M:%S)] PASS $bench — $k simpoints (${dt}s)" | tee -a "$LOG"
    else
        echo "[$(date +%H:%M:%S)] FAIL $bench (exit $exit_code, ${dt}s) — see $outbase.simpoint.log" | tee -a "$LOG"
    fi
}

export -f run_simpoint
export SIMPOINT SIMPOINT_DIR MAXK LOG

active=0
for bbv in "${BBV_FILES[@]}"; do
    run_simpoint "$bbv" &
    ((active++))
    if [ $active -ge $JOBS ]; then
        wait -n 2>/dev/null || wait
        ((active--))
    fi
done
wait

echo "[$(date +%H:%M:%S)] Sanity complete" | tee -a "$LOG"
echo
echo "=== Simpoint output check ==="
for bbv in "${BBV_FILES[@]}"; do
    bench=$(basename "$bbv" .bb.0.bb)
    sp=$SIMPOINT_DIR/$bench.simpoints
    wt=$SIMPOINT_DIR/$bench.weights
    if [ ! -f "$sp" ] || [ ! -s "$sp" ]; then
        echo "MISSING    $bench"
    elif [ ! -f "$wt" ] || [ ! -s "$wt" ]; then
        echo "NO_WEIGHTS $bench"
    else
        k=$(wc -l < "$sp")
        wsum=$(awk '{s+=$1} END {printf "%.3f", s}' "$wt")
        echo "OK         $bench — $k simpoints, weight_sum=$wsum"
    fi
done
