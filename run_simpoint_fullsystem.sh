#!/bin/bash
# run_simpoint_fullsystem.sh
#
# Runs SimPoint clustering on the full-system BBVs produced by
# bbv_qemu_system.sh and writes .simpoints / .weights / .labels per
# workload into a dedicated full-system simpoint directory.
#
# Sister to run_simpoint.sh (user-mode flow). The qemu plugin in this
# tree (qemu/contrib/plugins/bbv.c) already shifts BB indices by +1, so
# fixup_bbvs.sh is NOT needed before running this.
#
# Usage:
#   ./run_simpoint_fullsystem.sh                       # intspeed, default dirs
#   ./run_simpoint_fullsystem.sh --suite fpspeed
#   ./run_simpoint_fullsystem.sh --jobs 8 --maxk 30
#   ./run_simpoint_fullsystem.sh --bbv-dir /path/to/bbvs --simpoint-dir /path/out

set -u

SIMPOINT=/home/jht9sy/work/simpoint/bin/simpoint
BBV_ROOT=/data/akrish/riscv-spec2017-bbvs
SIMPOINT_ROOT=/data/akrish/riscv-simpoints
JOBS=11
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

BBV_DIR=${BBV_DIR_OVERRIDE:-$BBV_ROOT/${SUITE}-fullsystem}
SIMPOINT_DIR=${SIMPOINT_DIR_OVERRIDE:-$SIMPOINT_ROOT/${SUITE}-fullsystem}

if [ ! -d "$BBV_DIR" ]; then
    echo "ERROR: $BBV_DIR does not exist — run bbv_qemu_system.sh --suite $SUITE first"
    exit 1
fi
if [ ! -x "$SIMPOINT" ]; then
    echo "ERROR: SimPoint binary not found at $SIMPOINT"
    exit 1
fi

# Fail fast if there are no BBVs to cluster
shopt -s nullglob
BBV_FILES=( "$BBV_DIR"/*.bb.0.bb )
shopt -u nullglob
if [ ${#BBV_FILES[@]} -eq 0 ]; then
    echo "ERROR: no .bb.0.bb files found in $BBV_DIR"
    exit 1
fi

mkdir -p "$SIMPOINT_DIR"
LOG=$SIMPOINT_DIR/simpoint.log
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
        echo "[$(date +%H:%M:%S)] DONE $bench — $k simpoints (${dt}s)" | tee -a "$LOG"
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

echo "[$(date +%H:%M:%S)] All simpoint jobs complete" | tee -a "$LOG"
echo
echo "=== Summary ==="
for bbv in "${BBV_FILES[@]}"; do
    bench=$(basename "$bbv" .bb.0.bb)
    sp=$SIMPOINT_DIR/$bench.simpoints
    if [ -f "$sp" ] && [ -s "$sp" ]; then
        k=$(wc -l < "$sp")
        echo "OK    $bench — $k simpoints"
    else
        echo "FAIL  $bench — no output"
    fi
done
