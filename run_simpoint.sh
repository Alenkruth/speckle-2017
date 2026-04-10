#!/bin/bash
# Usage: ./run_simpoint.sh --suite intspeed|fpspeed [--jobs N] [--maxk K]
# Runs SimPoint clustering on each BBV file in $BBV_DIR and writes
# .simpoints / .weights / .labels per benchmark into $SIMPOINT_DIR.

SIMPOINT=/home/jht9sy/work/simpoint/bin/simpoint
SUITE=intspeed
JOBS=4
MAXK=30

while [[ $# -gt 0 ]]; do
    case $1 in
        --suite) SUITE=$2; shift 2 ;;
        --jobs)  JOBS=$2;  shift 2 ;;
        --maxk)  MAXK=$2;  shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

BBV_DIR=/data/akrish/riscv-spec2017-bbvs/${SUITE}-fixed
SIMPOINT_DIR=/data/akrish/riscv-simpoints/$SUITE

if [ ! -d "$BBV_DIR" ]; then
    echo "ERROR: $BBV_DIR does not exist"
    exit 1
fi

mkdir -p $SIMPOINT_DIR
LOG=$SIMPOINT_DIR/simpoint.log
echo "[$(date +%H:%M:%S)] Suite=$SUITE Jobs=$JOBS MaxK=$MAXK" | tee $LOG

run_simpoint() {
    local bbv=$1
    local bench=$(basename $bbv .bb.0.bb)
    local outbase=$SIMPOINT_DIR/$bench

    if [ -f "$outbase.simpoints" ] && [ -s "$outbase.simpoints" ]; then
        echo "[$(date +%H:%M:%S)] SKIP $bench (exists)" | tee -a $LOG
        return
    fi

    echo "[$(date +%H:%M:%S)] START $bench" | tee -a $LOG

    $SIMPOINT \
        -loadFVFile $bbv \
        -maxK $MAXK \
        -saveSimpoints $outbase.simpoints \
        -saveSimpointWeights $outbase.weights \
        -saveLabels $outbase.labels \
        > $outbase.simpoint.log 2>&1

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        local k=$(wc -l < $outbase.simpoints)
        echo "[$(date +%H:%M:%S)] DONE $bench — $k simpoints" | tee -a $LOG
    else
        echo "[$(date +%H:%M:%S)] FAIL $bench (exit $exit_code) — see $outbase.simpoint.log" | tee -a $LOG
    fi
}

export -f run_simpoint
export SIMPOINT SIMPOINT_DIR MAXK LOG

# Job pool
active=0
for bbv in $BBV_DIR/*.bb.0.bb; do
    run_simpoint "$bbv" &
    ((active++))
    if [ $active -ge $JOBS ]; then
        wait -n 2>/dev/null || wait
        ((active--))
    fi
done
wait

echo "[$(date +%H:%M:%S)] All simpoint jobs complete" | tee -a $LOG
echo ""
echo "=== Summary ==="
for bbv in $BBV_DIR/*.bb.0.bb; do
    bench=$(basename $bbv .bb.0.bb)
    sp=$SIMPOINT_DIR/$bench.simpoints
    if [ -f "$sp" ] && [ -s "$sp" ]; then
        k=$(wc -l < $sp)
        echo "OK    $bench — $k simpoints"
    else
        echo "FAIL  $bench — no output"
    fi
done
