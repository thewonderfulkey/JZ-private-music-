# -*- coding: utf-8 -*-
"""解析 ARM64 ELF 的 .dynsym 导出符号（不依赖 nm）。"""
import io
import os
import struct

TMP = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_libs"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_symbols.txt"


def parse(path):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        return ["not elf"]
    is64 = data[4] == 2
    le = data[5] == 1
    e_shoff = struct.unpack("<Q" if is64 else "<I", data[0x28:0x30 if is64 else 0x2C])[0]
    e_shentsize = struct.unpack("<H", data[0x3A:0x3C])[0]
    e_shnum = struct.unpack("<H", data[0x3C:0x3E])[0]
    e_shstrndx = struct.unpack("<H", data[0x3E:0x40])[0]
    shs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh = struct.unpack("<IIQQQQIIQQ", data[off:off + 64])
        shs.append(sh)
    shstr = shs[e_shstrndx]
    stroff = shstr[4]
    out = []
    dynsym_idx = None
    for i, sh in enumerate(shs):
        name_off = sh[0]
        nm = data[stroff + name_off: stroff + name_off + 40].split(b"\x00")[0].decode("latin-1")
        if nm == ".dynsym":
            dynsym_idx = i
        if nm in (".dynstr",):
            pass
    if dynsym_idx is None:
        return ["no .dynsym"]
    sh = shs[dynsym_idx]
    strtab_sh = shs[sh[6]]
    strtab_off = strtab_sh[4]
    entsize = sh[9] or 24
    count = sh[5] // entsize
    for j in range(count):
        off = sh[4] + j * entsize
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack("<IBBHQQ", data[off:off + 24])
        if st_name == 0:
            continue
        nm = data[strtab_off + st_name: strtab_off + st_name + 300].split(b"\x00")[0].decode("latin-1")
        out.append("%-6d %-16x %6d  %s" % (st_shndx, st_value, st_size, nm))
    return out


lines = []
for name in ["libcenbridge.so", "libMflacCrypto.so"]:
    p = os.path.join(TMP, name)
    lines.append("#### %s" % name)
    lines += parse(p)
    lines.append("")
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("ok", len(lines))
