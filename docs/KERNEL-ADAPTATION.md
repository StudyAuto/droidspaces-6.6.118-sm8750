# 内核适配指南（换内核 / 换机型 / 重编译时必读）

本文是**唯一**的「如何让模块在新内核上加载成功」流程书。
记录的是 2026-11-04 实测跑通的完整方法论，不是推测。

> 目标内核：`6.6.118-android15-8-g899dc6830d9c-abogki500782043-lotus-4k`
> 设备：OnePlus PJZ110 / OP5D0DL1，Android 16，`PJZ110_16.0.10.501(CN01)`

---

## 0. 一句话结论

**模块能否加载，100% 取决于符号 CRC 是否与设备内核一致。**
CRC 由 `genksyms` 按**头文件声明文本 + 配置**算出，所以：

- 配置差一项（尤其 BTF）→ CRC 不同 → 全部模块 `insmod` 失败
- 源码树不是同一个 commit → CRC 可能不同 → 同上

---

## 1. 三道关卡（按顺序失败）

| # | 关卡 | 失败表现 | 根因 |
|---|---|---|---|
| 1 | vermagic | `invalid module format` | 内核小版本/`LOCALVERSION` 不符 |
| 2 | `module_layout` CRC | `disagrees about version of symbol module_layout` | `struct module` 布局不同 |
| 3 | 其它符号 CRC | `disagrees about version of symbol xxx` | 该符号的结构体/签名不同 |

第 2、3 关都靠 `__versions` 段里的 CRC 判定。**`__versions` 为空时内核会跳过 CRC，
但这不代表安全**——它只是没校验，布局不匹配照样运行时炸。

---

## 2. 取设备权威符号表（核心步骤）

这是整个流程的**基准**。没有它，你无法知道设备要的是什么。

### 2.1 为什么不能靠「编一遍内核」

设备内核是**第三方基于官方源码的 fork**（commit `899dc6830d9c` 不在
upstream/cctv18 仓库）。即使配置完全一致，源码文本差异也会让 genksyms
算出不同的 CRC。

### 2.2 从 boot 分区提取（推荐，零风险）

内核镜像里就有符号表，直接读文件，**不需要在设备上跑任何内核代码**。

```sh
ADB=/mnt/c/Windows/System32/adb.exe

# 1) dump boot 分区（只读）
$ADB shell 'dd if=/dev/block/by-name/boot_a of=/data/local/tmp/boot_a.img bs=1048576'
$ADB pull /data/local/tmp/boot_a.img ./boot_a.img

# 2) 取运行时符号地址（kptr_restrict 默认 2，会全显示 0）
$ADB shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
$ADB shell 'for s in _text __start___ksymtab __stop___ksymtab \
  __start___ksymtab_gpl __stop___ksymtab_gpl \
  __start___kcrctab __stop___kcrctab \
  __start___kcrctab_gpl __stop___kcrctab_gpl; do grep -m1 " $s\$" /proc/kallsyms; done'
$ADB shell 'echo 2 > /proc/sys/kernel/kptr_restrict'   # 还原
```

### 2.3 拆包与定位

Android boot header v4：

- 偏移 `40` = `header_version`
- 偏移 `8` = `kernel_size`
- 内核数据从 **`header_size`（通常 1584）** 之后开始

⚠️ **但内核在文件里的真实起点可能是 4096**（页对齐）。
判据：找 `ARM\x64` 魔数，它固定位于 `Image` 头部偏移 `0x38`。

```python
sig = b'ARM\x64'
idx = data.find(sig)
image_start = idx - 0x38          # 实测 4096
image_size  = <Image 头偏移 16 的 u64>   # 实测 0x2470000
```

然后：`文件偏移 = 运行时地址 - _text + image_start`

> OnePlus 的内核是**未压缩**的原生 `Image`（`code0=0xfa405a4d`），
> 不需要 lz4/gzip。若遇到压缩，先解压再找 `ARMd`。

### 2.4 解析 ksymtab

每个条目 12 字节，三段都是 **相对自身地址的 s32 偏移**：

```python
v, name_off, ns_off = struct.unpack_from('<iii', img, off(base))
value     = (base + 0       + v)       & 0xFFFFFFFFFFFFFFFF
name_addr = (base + 4       + name_off) & 0xFFFFFFFFFFFFFFFF
ns_addr   = (base + 8       + ns_off)   & 0xFFFFFFFFFFFFFFFF
```

`__kcrctab` 与 `__ksymtab` **逐条一一对应**（`index` 相同）。

### 2.5 必须做的交叉验证

用设备**真实 vendor 模块**的 `__versions` 反查你提取的表：

```sh
adb pull /vendor/lib/modules/boot_stats.ko
python3 .github/scripts/check-symvers.py device-6.6.118.symvers boot_stats.ko
```

2026-11-04 实测：`boot_stats.ko` 11/11、`bam_dma.ko` 84/84 全中。
**一个都对不上说明偏移算错了，别往下走。**

### 2.6 产物

`__ksymtab`（3395 条）+ `__ksymtab_gpl`（5721 条）= **9116 条**，
写入 `.github/symvers/device-<版本>.symvers`。

---

## 3. 编译侧的三个坑

### 3.1 ⚠️ 必须装 pahole（否则 module_layout 必错）

**这是 2026-11-03 卡住整轮的真凶。**

设备 `CONFIG_DEBUG_INFO_BTF_MODULES=y`，`struct module` 里有
`btf_data` / `btf_data_size` 两个字段。这两项是 `DEBUG_INFO_BTF` 的
**依赖项**，缺 `pahole` 时 `olddefconfig` 会**静默关掉**它们。

后果：`struct module` 中间字段整体位移 48 字节。因为末尾有
`android_kabi_reserved1..4` 垫着，**`sizeof` 完全不变**，
所以只看大小发现不了——只有 CRC 会变。

```yaml
- run: sudo apt-get install -y pahole zstd
# Ubuntu 24.04 自带 1.25，与设备 CONFIG_PAHOLE_VERSION=125 一致
```

必须在 `olddefconfig` **之后**硬断言（不能只信输入配置）：

```sh
for k in CONFIG_DEBUG_INFO_BTF CONFIG_DEBUG_INFO_BTF_MODULES; do
  grep -q "^$k=y" out/.config || { echo "✗ $k 被关了"; exit 1; }
done
```

> 修好后：`module_layout` 从 `0x6500052f` 自动变成设备要的 `0x4e276f37`，
> 且**全部 645 个导入符号自动对齐**，一条都不用改。

### 3.2 必须关 `CONFIG_TRIM_UNUSED_KSYMS`

开了会让 modpost 因 93 个被裁掉的导出符号报 undefined，编不过。
**它不影响 CRC**（实测开/关 `module_layout` CRC 相同）。

### 3.3 配置必须去 CRLF

从 `adb shell` 拉回来的 config 带 `\r`，会让
`CONFIG_LOCALVERSION="-4k\r"` 等字符串配置多一个字符：

```sh
tr -d '\r' < .github/kconfig/device-<ver>.config > out/.config
```

---

## 4. 合并设备符号表（兜底）

即便修好 §3.1，仍建议在 modpost 前把设备权威表合并进去。
作用是**兜底那些本地源码树复现不出的符号**。

注意是**合并**不是替换：

- 设备表：`module_layout` 等内核导出符号的权威值
- 本地表：可能还有设备没有的符号（我们模块间互相导出）

直接替换会让这些符号报 undefined。

```sh
cp out/Module.symvers out/Module.symvers.ksrc
python3 .github/scripts/merge-symvers.py \
  .github/symvers/device-<ver>.symvers \
  out/Module.symvers.ksrc \
  out/Module.symvers
# 冲突时设备优先
```

---

## 5. 出货前闸门（不可跳过）

```sh
python3 .github/scripts/check-symvers.py \
  .github/symvers/device-<ver>.symvers $(find src -name '*.ko')
```

逐条比对每个 `.ko` 的 `__versions`：

- 符号在设备表里不存在 → 无法加载
- CRC 不一致 → 无法加载
- 模块间互相导出的符号 → 自动豁免

**只有全绿才能装机。**

---

## 6. 换新内核时的完整清单

按顺序做，每步都有验证点：

1. **取设备配置**
   `zcat /proc/config.gz > device-<新版本>.config`，`tr -d '\r'`
   - 更好的方式：直接从 boot 镜像里切 `IKCFG_ST`..`IKCFG_ED`，
     避免 `adb shell` 破坏二进制（用 `exec-out` 或 `pull`）
2. **取设备符号表** → 走 §2，产出 `.github/symvers/device-<新版本>.symvers`
3. **交叉验证** → §2.5，用 2 个 vendor ko 验证，必须 100% 命中
4. **确认内核源码分支** 与设备 `uname -r` 的 commit 对应
5. **装 pahole** 并断言 BTF 两项为 `y`
6. **编内核 + 合并 symvers + 编模块**
7. **过闸门** §5
8. **上机逐个 `insmod`**，顺序：`droid_lkm` → `vendor` → `misc` → `pids` → 网络

### 常用命令

```sh
# 内核版本与配置
adb shell 'uname -r; zcat /proc/config.gz | grep -E "CONFIG_(USER_NS|DEBUG_INFO_BTF|MODVERSIONS)"'

# 符号表边界（kptr_restrict 必须为 0）
adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict; grep -E "__ksymtab|__kcrctab" /proc/kallsyms | head'

# 检查某个符号设备期望的 CRC
grep -P '\t<符号名>\t' .github/symvers/device-*.symvers

# 检查某个 ko 实际携带的 CRC
python3 .github/scripts/check-symvers.py .github/symvers/device-*.symvers foo.ko
```

---

## 7. 排查表

| 现象 | 根因 | 动作 |
|---|---|---|
| `disagrees ... module_layout` | BTF 被关 / 源码树不同 | 查 §3.1，再看 CRC 分布 |
| `disagrees ... <其它符号>` | 该符号类型定义不同 | 对比 BTF/DWARF，或合并设备表 |
| `Unknown symbol xxx (err -2)` | 符号**未导出**（不是 CRC 问题） | 查 `/proc/kallsyms` 有无；无则走 inline hook |
| `invalid module format` | vermagic 不符 | 检查 `LOCALVERSION` 与内核小版本 |
| `Exec format error`（无 dmesg） | 同 vermagic 或架构不符 | `modinfo -F vermagic` |
| `CFI failure ...` 后关机 | clang 与内核不匹配 | 必须用内核同版本 clang |
| 加载成功但运行时报 `-EINVAL` | 运行时校验过严（非 CRC） | 见 §8 |

---

## 8. 历史踩坑：把 4 字节对齐当 8 字节

`userns_owner.c` 的 `is_text()` 曾写成：

```c
!(addr & (sizeof(void *) - 1))    /* 8 字节对齐 —— 错 */
```

**AArch64 指令固定 4 字节，编译器只保证函数 4 字节对齐。**
设备实测：`mntns_get=...f304`、`mntns_owner=...f53c`，都不是 8 的倍数。

结果：`mntns_owner` 被判非法 → `mntns_ops_resolve()` 返回 `-EINVAL`
→ `userns unsupported: -22`。

正确写法按**指令宽度**判：

```c
#define DROID_LKM_USERNS_FUNC_ALIGN 4UL
!(addr & (DROID_LKM_USERNS_FUNC_ALIGN - 1))
```

> 教训：**「指针」和「函数入口」的对齐要求不是一回事。**
> 凡是拿 `sizeof(void *)` 当对齐单位去校验函数地址，在 arm64 上都是错的。

---

## 9. 不要在设备上跑探针导出符号表

试过、都失败、别再重复：

| 方案 | 结果 |
|---|---|
| `filp_open` + `kernel_write` | `Unknown symbol filp_open (err -2)`（未导出） |
| `proc_create` + `seq_printf` | **insmod 时内核 panic、设备重启**（`proc_ops`/`seq_file` ABI 不匹配） |
| `pr_info` 分块打印 | 可用但需多次加载，效率低 |
| 读 `/proc/kcore` | 设备无此文件 |
| 读 `/dev/mem` | 设备无此节点 |

**直接从 boot 镜像解析**是唯一零风险且一次完成的路径。
