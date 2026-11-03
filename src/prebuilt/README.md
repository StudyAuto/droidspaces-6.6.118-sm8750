# 预编译产物

6 个 `.ko` 在 [`../dsm/ko/`](../dsm/ko/)（KernelSU 模块实际使用的位置）。

校验和见 [`MD5SUMS.txt`](MD5SUMS.txt)：

```
840b6048b285df42c666bbf63cbb80ad  droid_lkm.ko
f1db22a678de9df6cf1c3bdd093bd82d  droid_lkm_vendor.ko
c835b721a16fa2d7df72ef856b84112f  droid_lkm_misc.ko
6c8e0ca02ebba54b186a38780a5ddbc5  droid_lkm_pids.ko
d142ffd92002e7b08248ed4a6a4a9a99  macvlan.ko
7fc906bd39c8507607a70f2762c65fd2  ip6table_nat.ko
```

这 6 个 ko 由本仓库源码用 DDK (`android15-6.6` / clang r510928) 编译，
vermagic 是 `6.6.127-4k-g46a034eca005-dirty`。

> **为什么 6.6.127 编的能进 6.6.118**：设备 `CONFIG_MODVERSIONS=y`，
> 内核 `same_magic()` 在模块带 `__versions` crc 时跳过首段版本号，
> 只比较空格后的 `SMP preempt mod_unload modversions aarch64`。
> 已在真机验证（6 个模块全部 `insmod` rc=0）。详见 [`../../CHANGELOG.md`](../../CHANGELOG.md)。

`droid_lkm_pids.ko` 含 pids 显示层与功能层，可单独 `rmmod` / `insmod`；
功能层的自检方式见
[`../../docs/PIDS-ENFORCEMENT.md`](../../docs/PIDS-ENFORCEMENT.md#6-pidsstats自检计数器)
（`pids.stats` 里 `refused > 0` 即生效）。

网络模块（macvlan / ip6table_nat）重新编译后 md5 会不同，
原因是 `.text` 里嵌入了编译时的源文件绝对路径（`__FILE__`），
导出符号表则完全一致。功能等价。

> ⚠ 这批 ko **只在 OP5D0DL1 / 6.6.118 上真机验证过**。
> 别的机型/内核请看 [`../../docs/BUILD-FOR-OTHERS.md`](../../docs/BUILD-FOR-OTHERS.md) 重新编译。
