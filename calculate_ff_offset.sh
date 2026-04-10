#!/bin/bash
# calc_ckpt_offsets.sh
# Usage: ./calc_ckpt_offsets.sh --suite intspeed|fpspeed

SUITE=intspeed
INTERVAL=100000000
SP_DIR=/data/akrish/riscv-simpoints

while [[ $# -gt 0 ]]; do
    case $1 in
        --suite) SUITE=$2; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

OVERHEAD_FILE=$SP_DIR/${SUITE}_pk_overhead.txt
OUT=$SP_DIR/${SUITE}_ckpt_offsets.txt

if [ ! -f "$OVERHEAD_FILE" ]; then
    echo "ERROR: $OVERHEAD_FILE not found — run measure_pk_overhead.sh first"
    exit 1
fi

echo "# bench cluster interval instructions hex" > $OUT

for sp_file in $SP_DIR/$SUITE/*.simpoints; do
    bench=$(basename $sp_file .simpoints)

    # Look up pk overhead for this benchmark
    overhead=$(awk -v b=$bench '$1==b {print $2}' $OVERHEAD_FILE)
    if [ -z "$overhead" ]; then
        echo "WARN: no overhead found for $bench, skipping"
        continue
    fi

    echo ""
    echo "=== $bench (pk_overhead=$overhead) ==="
    printf "%-12s %-12s %-22s %-20s\n" "Cluster" "Interval" "Instructions" "Hex (-i value)"
    echo "--------------------------------------------------------------------"

    while read interval cluster; do
        adjusted=$(( interval * INTERVAL + overhead ))
        hex=$(python3 -c "print(hex($adjusted))")
        printf "%-12s %-12s %-22s %-20s\n" "$cluster" "$interval" "$adjusted" "$hex"
        echo "$bench $cluster $interval $adjusted $hex" >> $OUT
    done < "$sp_file"
done

echo ""
echo "Results saved to $OUT"