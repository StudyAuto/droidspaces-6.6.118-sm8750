#!/usr/bin/env python3
"""校验每个 .ko 的 __versions 与设备权威符号表逐个一致。

这是**出货前的最后一道闸门**。内核在 insmod 时对每个导入符号比对 CRC，
只要有一个不同就报 "disagrees about version of symbol xxx" 并拒绝加载；
更糟的是 CRC 相同但结构体布局不同时能加载、运行时才炸。

所以这里不做抽样，逐条全量比对：
  - 导入符号在设备表里不存在  → 该模块无法加载
  - CRC 与设备表不一致        → 该模块无法加载

用法：
    check-symvers.py <设备权威.symvers> <ko 文件>...
"""

import struct
import sys


def read_versions(path):
    """解析 ELF 的 __versions 段，返回 {symbol: crc32}。

    段内每个条目是 struct modversion_info（64 字节）：
        0..7    unsigned long crc   （64 位下占 8 字节）
        8..71   char name[MODULE_NAME_LEN]
    """
    with open(path, "rb") as fh:
        data = fh.read()

    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    def section(i):
        return struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)

    str_tab_off = section(e_shstrndx)[4]

    versions = {}
    for i in range(e_shnum):
        head = section(i)
        name_off = head[0]
        name_end = data.index(b"\0", str_tab_off + name_off)
        name = data[str_tab_off + name_off:name_end].decode()
        if name != "__versions":
            continue
        offset, size = head[4], head[5]
        for k in range(size // 64):
            entry = data[offset + k * 64: offset + (k + 1) * 64]
            crc = struct.unpack_from("<I", entry, 0)[0]
            sym = entry[8:].split(b"\0")[0].decode()
            versions[sym] = crc
    return versions


def read_exports(path):
    """返回本模块导出的符号名集合。

    直接读 __ksymtab_strings 段：内核的 KSYMTAB_ENTRY 宏把每个导出符号的
    名字都放进这一段（首字节是 '\0' 的空串是段首哨兵，跳过）。

    不用遍历 __ksymtab 逐条解析相对寻址的原因：.ko 是 ET_REL，
    所有段的 sh_addr 都是 0，段内偏移要配合 .rela__ksymtab* 才能换算成
    真实地址，绕一大圈还要处理重定位。而 __ksymtab_strings 里就是
    可直接切分的一串以 '\0' 结尾的符号名，没有歧义。

    用途：droid_lkm 系列模块之间有互相导出（如
    droid_lkm_ns_kind_register），这类符号设备内核表里当然没有，
    不能算「设备无此符号」。
    """
    with open(path, "rb") as fh:
        data = fh.read()

    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    def section(i):
        return struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)

    str_tab_off = section(e_shstrndx)[4]

    exports = set()
    for i in range(e_shnum):
        head = section(i)
        name_off = head[0]
        name_end = data.index(b"\0", str_tab_off + name_off)
        name = data[str_tab_off + name_off:name_end].decode()
        if name != "__ksymtab_strings":
            continue
        offset, size = head[4], head[5]
        for chunk in data[offset:offset + size].split(b"\0"):
            if chunk:
                exports.add(chunk.decode("utf-8", "replace"))
    return exports


def load_device_symvers(path):
    table = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 4:
                continue
            table[fields[1]] = int(fields[0], 16)
    return table


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip())
        return 2

    device = load_device_symvers(argv[1])
    failed = False

    # 先前扫一遍所有模块的导出符号，供跨模块引用豁免
    module_exports = set()
    for path in argv[2:]:
        try:
            module_exports |= read_exports(path)
        except Exception:
            pass

    for path in argv[2:]:
        versions = read_versions(path)
        missing = [s for s in versions
                   if s not in device and s not in module_exports]
        wrong = [(s, versions[s], device[s]) for s in versions
                 if s in device and device[s] != versions[s]]
        cross = [s for s in versions
                 if s not in device and s in module_exports]

        short = path.rsplit("/", 1)[-1]
        if not missing and not wrong:
            extra = "（另有 %d 个模块间符号）" % len(cross) if cross else ""
            print("  ✓ %-24s %3d 个导入符号全部与设备一致%s"
                  % (short, len(versions), extra))
            continue

        failed = True
        print("  ✗ %-24s %3d 个导入符号中 %d 个不存在、%d 个 CRC 不符"
              % (short, len(versions), len(missing), len(wrong)))
        for sym in missing[:10]:
            print("       设备无此符号: %s" % sym)
        for sym, ours, dev in wrong[:10]:
            print("       CRC 不符: %-32s 我们 0x%08x / 设备 0x%08x" % (sym, ours, dev))

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
