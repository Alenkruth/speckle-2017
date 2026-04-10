#!/bin/bash
# Usage: ./fixup_bbvs.sh --suite intspeed|fpspeed [--jobs N]
# Shifts QEMU BBV basic-block IDs by +1 so SimPoint accepts them
# (SimPoint requires dimension IDs >= 1; QEMU plugin emits 0-indexed).
# Reads from $BBV_DIR and writes to ${BBV_DIR}-fixed/, preserving the
# original *.bb.0.bb filenames.
#
# Note: a patched bbv.c plugin (with bb->index + 1) avoids the need to
# run this on freshly generated BBVs. Use this only for existing files
# that were produced before the plugin patch.

SUITE=intspeed
JOBS=4

while [[ $# -gt 0 ]]; do
    case $1 in
        --suite) SUITE=$2; shift 2 ;;
        --jobs)  JOBS=$2;  shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

BBV_DIR=/data/akrish/riscv-spec2017-bbvs/$SUITE
FIXED_DIR=/data/akrish/riscv-spec2017-bbvs/${SUITE}-fixed

if [ ! -d "$BBV_DIR" ]; then
    echo "ERROR: $BBV_DIR does not exist"
    exit 1
fi

mkdir -p $FIXED_DIR
LOG=$FIXED_DIR/fixup.log
echo "[$(date +%H:%M:%S)] Fixing BBVs from $BBV_DIR -> $FIXED_DIR (jobs=$JOBS)" | tee $LOG

fixup_one() {
    local in=$1
    local out=$FIXED_DIR/$(basename $in)
    local bench=$(basename $in .bb.0.bb)

    if [ -f "$out" ] && [ -s "$out" ]; then
        echo "[$(date +%H:%M:%S)] SKIP $bench (exists)" | tee -a $LOG
        return
    fi

    local t0=$(date +%s)
    awk '{
        out=""
        for (i=1; i<=NF; i++) {
            if (i==1 && $i ~ /^T:[0-9]+:[0-9]+$/) {
                n=split($i, a, ":")
                out="T:" (a[2]+1) ":" a[3]
                continue
            }
            n=split($i, a, ":")
            if (n==3 && a[1]=="" && a[2] ~ /^[0-9]+$/ && a[3] ~ /^[0-9]+$/) {
                out=out " :" (a[2]+1) ":" a[3]
            } else {
                out=out " " $i
            }
        }
        print out
    }' $in > $out
    local dt=$(( $(date +%s) - t0 ))
    local sz=$(du -sh $out | cut -f1)
    echo "[$(date +%H:%M:%S)] DONE $bench — $sz (${dt}s)" | tee -a $LOG
}

export -f fixup_one
export FIXED_DIR LOG

active=0
for bbv in $BBV_DIR/*.bb.0.bb; do
    fixup_one "$bbv" &
    ((active++))
    if [ $active -ge $JOBS ]; then
        wait -n 2>/dev/null || wait
        ((active--))
    fi
done
wait

echo "[$(date +%H:%M:%S)] Fixup complete" | tee -a $LOG
echo ""
echo "=== Summary ==="
for bbv in $BBV_DIR/*.bb.0.bb; do
    bench=$(basename $bbv .bb.0.bb)
    out=$FIXED_DIR/$(basename $bbv)
    if [ -f "$out" ] && [ -s "$out" ]; then
        sz=$(du -sh $out | cut -f1)
        echo "OK    $bench — $sz"
    else
        echo "FAIL  $bench"
    fi
done
