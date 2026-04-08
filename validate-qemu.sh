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
    local binary=$(ls $bench_dir*_base.riscv-64 2>/dev/null | head -1)

    if [ -z "$binary" ]; then
        echo "[$(date +%H:%M:%S)] SKIP $bench (no binary)" | tee -a $LOG
        return
    fi

    local args=$(grep -oP '(?<=riscv-64 ).*' $bench_dir/run_workload0.sh | head -1)
    local outfile=$BBV_DIR/${bench}.bb

    echo "[$(date +%H:%M:%S)] START $bench" | tee -a $LOG
    cd $bench_dir

    timeout $TIMEOUT $QEMU \
        -plugin $PLUGIN,outfile=$outfile,interval=$INTERVAL \
        $binary $args \
        > $BBV_DIR/${bench}.stdout \
        2> $BBV_DIR/${bench}.stderr

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
export QEMU PLUGIN BBV_DIR INTERVAL TIMEOUT LOG

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
    bbv=$BBV_DIR/${bench}.bb
    if [ ! -f "$bbv" ]; then
        echo "MISSING  $bench"
    elif [ ! -s "$bbv" ]; then
        echo "EMPTY    $bench"
    else
        intervals=$(grep -c '^T:' $bbv)
        echo "OK       $bench — $intervals intervals"
    fi
done