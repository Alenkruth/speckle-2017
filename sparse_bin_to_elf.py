#!/usr/bin/env python3
"""
sparse_bin_to_elf.py

Converts a sparse memory binary dump (from spike `dump`) into a compact
loadable ELF without materialising zero pages.

objcopy -I binary reads the entire file and writes every byte into a single
.data section, turning a 32 GB sparse file into a 32 GB real file.  This
script uses SEEK_DATA/SEEK_HOLE instead, finds only the non-zero regions,
and writes one PT_LOAD segment per region.  The result is a few hundred MB
at most — the same as the workload's actual memory footprint.

Optionally adds tohost/fromhost as ELF symbols (needed by the testchip_dtm
loadmem path to initialise HTIF).

Usage:
    sparse_bin_to_elf.py <mem.bin> <mem.elf> <base_addr_hex> \\
        [--tohost <hex>] [--fromhost <hex>] [--delete-input]

Example:
    sparse_bin_to_elf.py mem.0x80000000.bin mem.elf 0x80000000 \\
        --tohost 0xdeadbeef --fromhost 0xcafebabe --delete-input
"""

import sys, os, struct, argparse

SEEK_DATA = 3   # Linux: find next data region
SEEK_HOLE = 4   # Linux: find next hole


def find_data_regions(f, file_size):
    """Return list of (file_offset, length) for all non-zero regions."""
    # Try fast sparse-file path first (requires ext4/xfs; fails on NFS/Lustre/GPFS)
    try:
        return _find_regions_sparse(f, file_size)
    except (OSError, ValueError):
        print('Note: filesystem does not support SEEK_DATA/SEEK_HOLE, '
              'falling back to full scan (may take a few minutes)', flush=True)
        return _find_regions_scan(f, file_size)


def _find_regions_sparse(f, file_size):
    regions = []
    offset = 0
    while offset < file_size:
        data_start = f.seek(offset, SEEK_DATA)
        if data_start >= file_size:
            break
        try:
            hole_start = f.seek(data_start, SEEK_HOLE)
        except OSError:
            hole_start = file_size
        hole_start = min(hole_start, file_size)
        length = hole_start - data_start
        if length > 0:
            regions.append((data_start, length))
        offset = hole_start
    return regions


def _find_regions_scan(f, file_size, chunk_size=4 * 1024 * 1024):
    """Scan file in 4 MB chunks, coalescing non-zero runs into regions."""
    regions = []
    region_start = None
    region_end = None
    f.seek(0)
    offset = 0
    reported = 0
    while offset < file_size:
        chunk = f.read(min(chunk_size, file_size - offset))
        if not chunk:
            break
        # Fast all-zero check: bytes(n) is zero-filled, comparison is C-level memcmp
        if chunk != bytes(len(chunk)):
            if region_start is None:
                region_start = offset
            region_end = offset + len(chunk)
        else:
            if region_start is not None:
                regions.append((region_start, region_end - region_start))
                region_start = None
        offset += len(chunk)
        # Progress every 4 GB
        if offset - reported >= 4 * 1024 ** 3:
            print(f'  scanned {offset / 2**30:.0f} / {file_size / 2**30:.0f} GB', flush=True)
            reported = offset
    if region_start is not None:
        regions.append((region_start, region_end - region_start))
    return regions


def pack_elf64_le(segments, base_addr, tohost=None, fromhost=None):
    """
    Build a 64-bit little-endian ELF binary.

    segments: list of (vaddr, bytes)
    Returns bytes object.
    """
    ET_EXEC   = 2
    EM_RISCV  = 243
    PT_LOAD   = 1
    SHT_NULL  = 0
    SHT_STRTAB = 3
    SHT_SYMTAB = 2
    STB_GLOBAL = 1
    STT_OBJECT = 1
    STV_DEFAULT = 0

    e_ehsize    = 64
    e_phentsize = 56
    e_shentsize = 64

    has_syms = (tohost is not None) or (fromhost is not None)

    num_ph = len(segments)

    # --- String tables ---
    # Section name string table: .shstrtab, .symtab, .strtab
    if has_syms:
        shstrtab = b'\x00.shstrtab\x00.symtab\x00.strtab\x00'
        idx_shstrtab = 1
        idx_symtab   = idx_shstrtab + len('.shstrtab\x00')   # 10
        idx_strtab   = idx_symtab   + len('.symtab\x00')     # 18

        # Symbol name string table: \0 tohost\0 fromhost\0
        sym_names = b'\x00'
        tohost_name_off = len(sym_names)
        sym_names += b'tohost\x00'
        fromhost_name_off = len(sym_names)
        sym_names += b'fromhost\x00'

        # Symbol table: Elf64_Sym (24 bytes each)
        # Entry 0: null symbol
        symtab  = struct.pack('<IBBHQQ', 0, 0, 0, 0, 0, 0)
        sym_idx = 1
        tohost_sym_idx = fromhost_sym_idx = None
        if tohost is not None:
            symtab += struct.pack('<IBBHQQ',
                tohost_name_off,
                (STB_GLOBAL << 4) | STT_OBJECT,
                STV_DEFAULT, 0xfff1,   # SHN_ABS
                tohost, 8)
            tohost_sym_idx = sym_idx; sym_idx += 1
        if fromhost is not None:
            symtab += struct.pack('<IBBHQQ',
                fromhost_name_off,
                (STB_GLOBAL << 4) | STT_OBJECT,
                STV_DEFAULT, 0xfff1,
                fromhost, 8)
            fromhost_sym_idx = sym_idx; sym_idx += 1

        num_sh = 4    # null, shstrtab, symtab, strtab
    else:
        shstrtab = b'\x00.shstrtab\x00'
        idx_shstrtab = 1
        symtab = sym_names = b''
        num_sh = 2    # null, shstrtab

    # Align all tables to 8 bytes
    def align8(b): return b + b'\x00' * ((-len(b)) % 8)
    shstrtab = align8(shstrtab)
    symtab   = align8(symtab)
    sym_names = align8(sym_names)

    # --- Layout ---
    # [ELF header] [program headers] [segment data...] [shstrtab] [symtab] [strtab] [section headers]
    headers_size = e_ehsize + num_ph * e_phentsize

    seg_offsets = []
    cur = headers_size
    for _, data in segments:
        seg_offsets.append(cur)
        cur += len(data)

    shstrtab_off = cur;           cur += len(shstrtab)
    symtab_off   = cur;           cur += len(symtab)   if has_syms else 0
    strtab_off   = cur;           cur += len(sym_names) if has_syms else 0
    sh_off       = (cur + 7) & ~7  # align section headers

    # --- ELF header ---
    entry = segments[0][0] if segments else base_addr
    ident = bytes([0x7f,0x45,0x4c,0x46, 2, 1, 1, 0]) + b'\x00'*8
    ehdr = ident + struct.pack('<HHIQQQIHHHHHH',
        ET_EXEC, EM_RISCV, 1,
        entry,          # e_entry
        e_ehsize,       # e_phoff
        sh_off,         # e_shoff
        0,              # e_flags
        e_ehsize,       # e_ehsize
        e_phentsize,    # e_phentsize
        num_ph,         # e_phnum
        e_shentsize,    # e_shentsize
        num_sh,         # e_shnum
        1,              # e_shstrndx (index of .shstrtab)
    )

    # --- Program headers ---
    PF_RWX = 7
    phdrs = b''
    for i, (vaddr, data) in enumerate(segments):
        size = len(data)
        phdrs += struct.pack('<IIQQQQQQ',
            PT_LOAD, PF_RWX,
            seg_offsets[i], vaddr, vaddr,
            size, size, 0x1000)

    # --- Section headers ---
    # 0: null
    shdrs = struct.pack('<IIQQQQIIQQ', 0,SHT_NULL,0,0,0,0,0,0,0,0)
    # 1: .shstrtab
    shdrs += struct.pack('<IIQQQQIIQQ',
        idx_shstrtab, SHT_STRTAB, 0, 0,
        shstrtab_off, len(shstrtab), 0, 0, 1, 0)
    if has_syms:
        # 2: .symtab
        sym_entry_size = 24
        shdrs += struct.pack('<IIQQQQIIQQ',
            idx_symtab, SHT_SYMTAB, 0, 0,
            symtab_off, len(symtab), 3, 1,   # sh_link=.strtab idx, sh_info=first global
            8, sym_entry_size)
        # 3: .strtab
        shdrs += struct.pack('<IIQQQQIIQQ',
            idx_strtab, SHT_STRTAB, 0, 0,
            strtab_off, len(sym_names), 0, 0, 1, 0)

    # --- Assemble ---
    buf = bytearray(ehdr + phdrs)
    for _, data in segments:
        buf += data
    buf += shstrtab
    if has_syms:
        buf += symtab
        buf += sym_names
    # pad to sh_off
    if len(buf) < sh_off:
        buf += b'\x00' * (sh_off - len(buf))
    buf += shdrs
    return bytes(buf)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('bin',     help='Input sparse binary (mem.<addr>.bin)')
    ap.add_argument('elf',     help='Output ELF path (mem.elf)')
    ap.add_argument('base',    help='Physical base address of the dump (hex)')
    ap.add_argument('--tohost',    help='tohost symbol address (hex)')
    ap.add_argument('--fromhost',  help='fromhost symbol address (hex)')
    ap.add_argument('--delete-input', action='store_true',
                    help='Delete input bin file on success')
    args = ap.parse_args()

    base_addr  = int(args.base, 16)
    tohost     = int(args.tohost,   16) if args.tohost   else None
    fromhost   = int(args.fromhost, 16) if args.fromhost else None

    file_size = os.path.getsize(args.bin)
    print(f'Input:  {args.bin} ({file_size / 2**30:.2f} GB logical)', flush=True)

    with open(args.bin, 'rb') as f:
        regions = find_data_regions(f, file_size)
        print(f'Regions: {len(regions)} non-zero chunks', flush=True)

        segments = []
        total_data = 0
        for (file_off, length) in regions:
            vaddr = base_addr + file_off
            f.seek(file_off)
            data = f.read(length)
            segments.append((vaddr, data))
            total_data += length
            print(f'  0x{vaddr:016x}  +{length / 2**20:.1f} MB', flush=True)

    if not segments:
        print('ERROR: no non-zero data found in binary', file=sys.stderr)
        sys.exit(1)

    print(f'Total data: {total_data / 2**20:.1f} MB', flush=True)

    elf_bytes = pack_elf64_le(segments, base_addr, tohost=tohost, fromhost=fromhost)

    with open(args.elf, 'wb') as f:
        f.write(elf_bytes)

    print(f'Output: {args.elf} ({len(elf_bytes) / 2**20:.1f} MB)', flush=True)

    if args.delete_input:
        os.unlink(args.bin)
        print(f'Deleted {args.bin}', flush=True)


if __name__ == '__main__':
    main()
