#!/bin/bash
# Usage: ./sanity_bbv.sh --suite intspeed|fpspeed [--jobs N] [--timeout SEC]

QEMU=/home/jht9sy/work/qemu/build/qemu-riscv64
PLUGIN=/home/jht9sy/work/qemu/build/contrib/plugins/libbbv.so
INTERVAL=100000000
TIMEOUT=300
SUITE=intspeed
JOBS=10

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --suite)  SUITE=$2;   shift 2 ;;
        --jobs)   JOBS=$2;    shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

BENCH_DIR=/home/jht9sy/work/speckle-2017/build/overlay/$SUITE
BBV_DIR=/data/akrish/riscv-spec2017-bbvs/bbv-sanity/$SUITE

if [ ! -d "$BENCH_DIR" ]; then
    echo "ERROR: $BENCH_DIR does not exist"
    exit 1
fi

mkdir -p $BBV_DIR
LOG=$BBV_DIR/sanity.log

echo "[$(date +%H:%M:%S)] Suite=$SUITE Jobs=$JOBS Timeout=${TIMEOUT}s" | tee $LOG

run_benchmark() {
    local bench_dir=$1
    local bench=$(basename $bench_dir)
    # Extract the actual binary name from run_workload0.sh (some dirs have multiple
    # *_base.riscv-64 binaries, e.g. 621.wrf_s has diffwrf_621_base.riscv-64)
    local binary_name=$(grep -v '^echo' $bench_dir/run_workload0.sh | grep -oP '\./\S+_base\.riscv-64' | head -1 | sed 's|^\./||')
    local binary="$bench_dir$binary_name"
    if [ ! -f "$binary" ]; then
        binary=$(ls $bench_dir*_base.riscv-64 2>/dev/null | head -1)
    fi

    if [ -z "$binary" ]; then
        echo "[$(date +%H:%M:%S)] SKIP $bench (no binary)" | tee -a $LOG
        return
    fi

    local raw_cmd=$(grep -v '^echo' $bench_dir/run_workload0.sh | grep -oP '(?<=riscv-64 ).*' | head -1)
    local args=""
    local stdin_file=""

    # For fp suites, handle stdin redirect (e.g. bwaves, roms: "< input.in")
    # and strip stdout/stderr redirects (e.g. wrf: "> rsl.out 2>> wrf.err")
    if [[ "$SUITE" == "fpspeed" || "$SUITE" == "fprate" ]]; then
        # Extract stdin file if present: "... < file.in"
        if [[ "$raw_cmd" =~ \<[[:space:]]*([^[:space:]]+) ]]; then
            stdin_file="${BASH_REMATCH[1]}"
        fi
        # Strip everything from the first redirect operator onwards
        args=$(echo "$raw_cmd" | sed -E 's/[[:space:]]*[<>].*$//')
    else
        args="$raw_cmd"
    fi

    local outfile=$BBV_DIR/${bench}.bb

    echo "[$(date +%H:%M:%S)] START $bench" | tee -a $LOG
    cd $bench_dir

    if [ -n "$stdin_file" ]; then
        timeout $TIMEOUT $QEMU \
            -plugin $PLUGIN,outfile=$outfile,interval=$INTERVAL \
            $binary $args \
            < "$stdin_file" \
            > $BBV_DIR/${bench}.stdout \
            2> $BBV_DIR/${bench}.stderr
    else
        timeout $TIMEOUT $QEMU \
            -plugin $PLUGIN,outfile=$outfile,interval=$INTERVAL \
            $binary $args \
            > $BBV_DIR/${bench}.stdout \
            2> $BBV_DIR/${bench}.stderr
    fi

    local exit_code=$?
    if [ $exit_code -eq 124 ]; then
        echo "[$(date +%H:%M:%S)] PASS $bench (ran full ${TIMEOUT}s)" | tee -a $LOG
    elif [ $exit_code -eq 0 ]; then
        echo "[$(date +%H:%M:%S)] PASS $bench (completed early — verify ref input)" | tee -a $LOG
    else
        echo "[$(date +%H:%M:%S)] FAIL $bench (exit $exit_code)" | tee -a $LOG
    fi
}

export -f run_benchmark
export QEMU PLUGIN BBV_DIR INTERVAL TIMEOUT LOG SUITE

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

echo "[$(date +%H:%M:%S)] Sanity complete" | tee -a $LOG
echo ""
echo "=== BBV output check ==="
for bench_dir in $BENCH_DIR/*/; do
    bench=$(basename $bench_dir)
    bbv=$(ls $BBV_DIR/${bench}.bb* 2>/dev/null | head -1)
    if [ -z "$bbv" ]; then
        echo "MISSING  $bench"
    elif [ ! -s "$bbv" ]; then
        echo "EMPTY    $bench"
    else
        intervals=$(grep -c '^T:' $bbv)
        echo "OK       $bench — $intervals intervals ($(basename $bbv))"
    fi
done