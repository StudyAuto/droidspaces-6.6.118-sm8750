# 构建速查

完整流程见 [`../docs/BUILD.md`](../docs/BUILD.md)。这里只放命令。

## 依赖

- DDK 镜像 `docker.cnb.cool/ylarod/ddk/ddk-min:android15-6.6`
  （内含 clang r510928 + KDIR 6.6.127 + 交叉工具链）
- 或者把该镜像解包成 rootfs，用 `DDK_ROOT` 指过去（docker 起不来时用）

## 命令

```bash
cd src

# chroot 模式（推荐）
DDK_ROOT=/tmp/ddk66/rootfs sh scripts/build-ddkk.sh     android15-6.6
DDK_ROOT=/tmp/ddk66/rootfs sh scripts/build-net-ddk.sh  android15-6.6

# docker 模式
sh scripts/build-ddkk.sh    android15-6.6
sh scripts/build-net-ddk.sh android15-6.6

# 打包成 KernelSU 模块
sh scripts/package-ksu-zip.sh
```

产物：

```
droid_lkm/out/android15-6.6/{droid_lkm,droid_lkm_vendor,droid_lkm_misc,droid_lkm_pids}.ko
net_macvlan/macvlan.ko
net_ip6nat/ip6table_nat.ko
dsm/ko/*.ko            ← 脚本自动拷过去，打包用这个
dist/Droidspaces-v1.0.0-6.6.zip
```

## 关键约束

| 约束 | 说明 |
|---|---|
| clang 必须用 DDK 里的 r510928 | 与设备原厂编内核的 clang 同一 build，否则 KCFI 崩 |
| `VER=android15-6.6` | 决定 KMI 与输出目录 |
| vermagic 首段 6.6.127 ≠ 设备 6.6.118 | **可以加载**：模块带 `__versions` crc 时内核只比较空格后的部分 |
| `macvlan_core.c` 用 6.6 源码 | 6.12 版本用了 `dev->lltx` / `change_proto_down`，6.6 没有这些成员 |
