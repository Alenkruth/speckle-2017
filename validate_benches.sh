#!/bin/bash
# validate_spike.sh
# Usage: ./validate_spike.sh [--suite intspeed|fpspeed] [--jobs N] [--timeout SEC]

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"
SPIKE=spike
PK=pk
ISA=rv64imafd
TIMEOUT=30
SUITE=intspeed
JOBS=10

while [[ $# -gt 0 ]]; do
    case $1 in
        --suite)   SUITE=$2;   shift 2 ;;
        --jobs)    JOBS=$2;    shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

BENCH_DIR=$SPECKLE_DIR/build/overlay/$SUITE
LOG=$SPECKLE_DIR/spike_validate_${SUITE}.log

if [ ! -d "$BENCH_DIR" ]; then
    echo "ERROR: $BENCH_DIR does not exist"
    exit 1
fi

echo "Spike validation — $(date)"           | tee $LOG
echo "Suite: $SUITE"                         | tee -a $LOG
echo "ISA: $ISA"                             | tee -a $LOG
echo "Jobs: $JOBS"                           | tee -a $LOG
echo "Timeout per benchmark: ${TIMEOUT}s"   | tee -a $LOG
echo "-----------------------------------"   | tee -a $LOG

# Shared counters via temp files (bash subshells can't share variables)
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_benchmark() {
    local bench_dir=$1
    local bench=$(basename $bench_dir)
    local binary=$(ls $bench_dir*_base.riscv-64 2>/dev/null | head -1)

    if [ -z "$binary" ]; then
        echo "SKIP  $bench (no binary found)" | tee -a $LOG
        return
    fi

    local run_script=$bench_dir/run_workload0.sh
    if [ ! -f "$run_script" ]; then
        echo "SKIP  $bench (no run_workload0.sh)" | tee -a $LOG
        return
    fi

    local args=$(grep -v '^echo' $run_script | grep -oP '(?<=riscv-64 ).*' | head -1)

    cd $bench_dir
    timeout $TIMEOUT $SPIKE --isa=$ISA $PK $binary $args \
        > /dev/null 2>&1
    local status=$?
    cd $SPECKLE_DIR

    if [ $status -eq 124 ]; then
        echo "PASS  $bench (timed out as expected)" | tee -a $LOG
        touch $TMPDIR/pass_${bench}
    elif [ $status -eq 0 ]; then
        echo "PASS  $bench (completed)" | tee -a $LOG
        touch $TMPDIR/pass_${bench}
    else
        echo "FAIL  $bench (exit code $status)" | tee -a $LOG
        touch $TMPDIR/fail_${bench}
    fi
}

export -f run_benchmark
export SPIKE PK ISA TIMEOUT SPECKLE_DIR LOG TMPDIR

# Job pool
active=0
for bench_dir in $BENCH_DIR/*/; do
    run_benchmark "$bench_dir" &
    ((active++))
    if [ $active -ge $JOBS ]; then
        wait -n 2>/dev/null || wait
        ((active--))
    fi
done
wait

pass=$(ls $TMPDIR/pass_* 2>/dev/null | wc -l)
fail=$(ls $TMPDIR/fail_* 2>/dev/null | wc -l)

echo "-----------------------------------" | tee -a $LOG
echo "Results: $pass passed, $fail failed" | tee -a $LOG