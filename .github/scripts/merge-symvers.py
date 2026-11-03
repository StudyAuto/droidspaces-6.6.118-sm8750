#!/usr/bin/env python3
"""合并「设备权威 Module.symvers」与「本地内核编译产物 Module.symvers」。

冲突时**设备值优先**。

原因：设备内核是第三方基于官方源码的 fork（commit 899dc6830d9c 不在
cctv18 仓库里），头文件声明文本有漂移；而 CONFIG_MODVERSIONS 的 CRC
由 genksyms 按声明文本算出。本地源码树即使配置完全一致，也算不出设备
的真值（实测 645 个导入符号里 265 个不一致）。

设备真值来源：boot_a 里的 vmlinux，解析 __ksymtab/__kcrctab 得到，
并用 /vendor/lib/modules 下的真实 .ko 的 __versions 交叉验证过。

用法：
    merge-symvers.py <设备权威.symvers> <内核产物.symvers> <输出.symvers>
"""

import sys


def load(path):
    """读 Module.symvers，返回 {name: (crc, module, export, namespace)}。"""
    table = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            fields = line.split("\t")
            if len(fields) < 4:
                continue
            crc, name, module, export = fields[0], fields[1], fields[2], fields[3]
            ns = fields[4] if len(fields) > 4 else ""
            table[name] = (crc, module, export, ns)
    return table


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip())
        return 2

    dev_path, ksrc_path, out_path = argv[1:4]
    dev = load(dev_path)
    ksrc = load(ksrc_path)

    overwritten = [n for n in dev if n in ksrc and ksrc[n][0] != dev[n][0]]
    only_kernel = [n for n in ksrc if n not in dev]

    merged = dict(ksrc)
    merged.update(dev)

    with open(out_path, "w", encoding="utf-8") as fh:
        for name in sorted(merged):
            crc, module, export, ns = merged[name]
            fh.write("%s\t%s\t%s\t%s\t%s\n" % (crc, name, module, export, ns))

    print("设备权威条目 %d，本地内核条目 %d，合并后 %d" % (len(dev), len(ksrc), len(merged)))
    print("  设备覆盖本地同名 %d 条（CRC 不一致，以设备为准）" % len(overwritten))
    print("  仅本地有 / 设备无 %d 条（模块一旦引用，insmod 必然失败）" % len(only_kernel))

    for name in ("module_layout",):
        if name in dev:
            print("  自检 %s = %s（设备权威值）" % (name, dev[name][0]))
        else:
            print("  ✗ 设备表里没有 %s，符号表可能不完整" % name)
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
