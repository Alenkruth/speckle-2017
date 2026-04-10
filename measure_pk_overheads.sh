#!/bin/bash
# measure_pk_overhead.sh
# Measures pk instruction overhead for each benchmark in a suite
# Usage: ./measure_pk_overhead.sh --suite intspeed|fpspeed

SPECKLE_DIR=/home/jht9sy/work/speckle-2017
SUITE=intspeed

while [[ $# -gt 0 ]]; do
    case $1 in
        --suite) SUITE=$2; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

BENCH_DIR=$SPECKLE_DIR/build/overlay/$SUITE
OUT=/data/akrish/riscv-simpoints/${SUITE}_pk_overhead.txt

echo "# benchmark pk_overhead_instructions" | tee $OUT

for bench_dir in $BENCH_DIR/*/; do
    bench=$(basename $bench_dir)
    binary=$(ls $bench_dir*_base.riscv-64 2>/dev/null | head -1)

    if [ -z "$binary" ]; then
        echo "SKIP $bench (no binary)"
        continue
    fi

    # Get entry point
    entry=$(riscv64-unknown-linux-gnu-readelf -h $binary \
        | awk '/Entry point/ {print $4}')

    # Zero-pad to 18 chars for matching: 0x0000000000019140
    entry_padded=$(python3 -c "print(f'0x{int(\"$entry\", 16):016x}')")

    # Measure pk overhead
    overhead=$(spike --isa=rv64imafdc \
        --pmpregions=0 \
        -m2147483648:268435456 \
        -l --log-commits \
        pk $binary \
        2>&1 | awk -v entry="$entry_padded" '
        {
            count++
            if ($0 ~ entry) {
                print count
                exit
            }
        }')

    echo "$bench $overhead" | tee -a $OUT
done

echo ""
echo "Results saved to $OUT"