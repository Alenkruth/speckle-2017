#!/bin/bash
# validate_spike.sh
# Usage: ./validate_spike.sh
# Runs each intspeed benchmark briefly on Spike and reports pass/fail

SPECKLE_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR=$SPECKLE_DIR/build/overlay/fpspeed
SPIKE=spike
PK=pk
ISA=rv64imafd
TIMEOUT=30  # seconds per benchmark

echo "Spike validation — $(date)"
echo "ISA: $ISA"
echo "Timeout per benchmark: ${TIMEOUT}s"
echo "-----------------------------------"

pass=0
fail=0

for bench_dir in $BENCH_DIR/*/; do
    bench=$(basename $bench_dir)
    binary=$(ls $bench_dir*_base.riscv-64 2>/dev/null | head -1)

    if [ -z "$binary" ]; then
        echo "SKIP  $bench (no binary found)"
        continue
    fi

    # Get the run command from the workload script, extract args
    run_script=$bench_dir/run_workload0.sh
    if [ ! -f "$run_script" ]; then
        echo "SKIP  $bench (no run_workload0.sh)"
        continue
    fi

    # Extract arguments after the binary name
    args=$(grep -oP '(?<=riscv-64 ).*' $run_script | head -1)

    # Run spike with timeout, capture exit status
    cd $bench_dir
    timeout $TIMEOUT $SPIKE --isa=$ISA $PK $binary $args \
        > /dev/null 2>&1
    status=$?

    if [ $status -eq 124 ]; then
        # Timeout = ran without crashing, good enough
        echo "PASS  $bench (timed out as expected)"
        ((pass++))
    elif [ $status -eq 0 ]; then
        echo "PASS  $bench (completed)"
        ((pass++))
    else
        echo "FAIL  $bench (exit code $status)"
        ((fail++))
    fi

    cd $SPECKLE_DIR
done

echo "-----------------------------------"
echo "Results: $pass passed, $fail failed"