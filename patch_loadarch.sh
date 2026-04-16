#!/bin/bash
# patch_loadarch.sh
#
# Post-processes checkpoint `loadarch` files that were generated with the
# earlier (broken) generate_checkpoints_fullsystem.sh that stripped the
# vector CSR reads from cmds_tmp.txt.
#
# The chipyard testchip_dtm.cc loadarch parser (testchip_dtm.cc:216-220)
# expects 5 vector CSR lines (vstart, vxsat, vxrm, vcsr, vtype) immediately
# after fcsr. If they're absent every subsequent CSR read is shifted by 5
# lines and the driver eventually crashes in substr(18) on a too-short line.
#
# This script detects loadarch files missing those lines and inserts 5 dummy
# "0x0000000000000000" lines right after the fcsr (line 5), giving the
# driver the correct non-V initial state (all-zero vector CSRs).
#
# Detection heuristic: line 6 of a correct loadarch is a vector CSR value.
# In broken loadarchs, line 6 is the stvec value (a valid hex). We can't
# distinguish those by content alone, so we count the total number of
# numeric-hex lines and compare against what the driver expects:
#   broken format: 89 lines (no 5 vector CSRs)
#   fixed format:  94 lines (includes 5 vector CSRs)
# (both +1 or +2 for nharts header and ":" separator)
#
# Idempotent: if the loadarch already has the vector CSR lines, leave it alone.
#
# Usage:
#   ./patch_loadarch.sh                              # patches every loadarch in default ckpt dir
#   ./patch_loadarch.sh --ckpt-dir /path/to/ckpt
#   ./patch_loadarch.sh --dry-run                    # report, don't modify
#   ./patch_loadarch.sh --file /path/to/loadarch     # patch one file

set -u

CKPT_DIR=/data/akrish/checkpoints
SUITE=intspeed
DRY_RUN=0
SINGLE_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --ckpt-dir) CKPT_DIR=$2; shift 2 ;;
        --suite)    SUITE=$2;    shift 2 ;;
        --dry-run)  DRY_RUN=1;   shift ;;
        --file)     SINGLE_FILE=$2; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Determine if a loadarch is already in the fixed format.
#
# The chipyard testchip_dtm.cc loadarch parser expects this structure:
#   line 1:   nharts count
#   line 2:   ":" separator
#   line 3:   pc
#   line 4:   priv mode letter (M/S/U)
#   line 5:   fcsr
#   line 6-10:  vector CSRs (vstart, vxsat, vxrm, vcsr, vtype)
#   line 11-16: super CSRs (stvec, sscratch, sepc, scause, stval, satp)
#   line 17-26: machine CSRs (mstatus..mip, 10 entries)
#   line 27-28: mcycle, minstret
#   line 29-30: mtime, mtimecmp
#   line 31-62: 32 FPRs
#   line 63-94: 32 GPRs
#   line 95:    trailing "VLEN=..." or dummy line (driver ALWAYS consumes one more)
#
# Total: 95 lines. The driver asserts `id == lines.size()` at the end.
is_fixed_format() {
    local f=$1
    local total=$(wc -l < "$f")
    [ "$total" -eq 95 ]
}

patch_one() {
    local f=$1

    if [ ! -f "$f" ]; then
        echo "SKIP  $f (not found)"
        return
    fi
    if [ ! -s "$f" ]; then
        echo "SKIP  $f (empty)"
        return
    fi

    # Only touch loadarch files for COMPLETED checkpoints.
    # The generator writes "1\n" to loadarch as the first step, then
    # appends spike's dump output after run completes. If mem.elf isn't
    # there yet, spike is still running — leave the file alone.
    local dir=$(dirname "$f")
    if [ ! -s "$dir/mem.elf" ]; then
        echo "SKIP  $f (mem.elf missing — spike still running?)"
        return
    fi

    if is_fixed_format "$f"; then
        echo "OK    $f (already has vector CSR lines)"
        return
    fi

    # Insert 5 dummy vector CSR lines after line 5 (the fcsr line).
    # Also append one trailing dummy line after the 32 GPRs to satisfy the
    # driver's `id++` at testchip_dtm.cc:283 (it always consumes one more
    # line past the GPRs, whether or not there's real vector data).
    #
    # The trailer MUST NOT contain the substring "VLEN" — if it does, the
    # driver (testchip_dtm.cc:256) thinks there's real vector data, tries
    # to parse 32 vreg lines past the end of the file, and substr() throws.
    # Use the same kind of trap message the old chipyard flow produced when
    # running `vreg 0` on a non-V spike.
    # Line 1 = nharts (1), line 2 = ":", line 3 = pc, line 4 = priv, line 5 = fcsr.
    local zero="0x0000000000000000"
    local trailer="0xReceived trap: trap_illegal_instruction"
    if [ "$DRY_RUN" = "1" ]; then
        echo "WOULD $f"
        return
    fi

    # Back up once (non-destructive)
    [ -f "${f}.unpatched" ] || cp "$f" "${f}.unpatched"

    awk -v z="$zero" -v tr="$trailer" '
        NR==5 {print; for(i=0;i<5;i++) print z; next}
        {print}
        END {print tr}
    ' "${f}.unpatched" > "$f.tmp"
    mv "$f.tmp" "$f"

    local total
    total=$(wc -l < "$f")
    echo "PATCH $f (total lines now: $total)"
}

if [ -n "$SINGLE_FILE" ]; then
    patch_one "$SINGLE_FILE"
    exit 0
fi

# Walk the checkpoint tree under both the full and sanity dirs
TARGET_DIRS=(
    "$CKPT_DIR/${SUITE}-fullsystem"
    "$CKPT_DIR/sanity/${SUITE}-fullsystem"
)

TOTAL=0
PATCHED=0
ALREADY=0
INCOMPLETE=0

for d in "${TARGET_DIRS[@]}"; do
    [ -d "$d" ] || continue
    echo "=== scanning $d ==="
    while IFS= read -r f; do
        ((TOTAL++))
        local_dir=$(dirname "$f")
        if [ ! -s "$local_dir/mem.elf" ]; then
            echo "SKIP  $f (incomplete — mem.elf missing)"
            ((INCOMPLETE++))
            continue
        fi
        if is_fixed_format "$f"; then
            echo "OK    $f"
            ((ALREADY++))
            continue
        fi
        patch_one "$f"
        [ "$DRY_RUN" = "0" ] && ((PATCHED++))
    done < <(find "$d" -name 'loadarch' -type f 2>/dev/null | sort)
done

echo
echo "=== Summary ==="
echo "Total loadarch files:    $TOTAL"
echo "Already in fixed format: $ALREADY"
echo "Incomplete (skipped):    $INCOMPLETE"
if [ "$DRY_RUN" = "1" ]; then
    echo "Would patch:             $((TOTAL - ALREADY - INCOMPLETE))"
else
    echo "Patched:                 $PATCHED"
fi
