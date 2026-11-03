# 从源码到 .ko 的完整构建流程

本文档记录从零到产出 6 个 ko 的**全部**步骤，可复现。
已在 2026-11-03 实跑通过。

---

## 0. 为什么必须用 Android DDK

目标内核 `6.6.118-android15-8-g899dc6830d9c-abogki500782043-lotus-4k` 开启了
**KCFI**（`CONFIG_CFI_CLANG=y`）。KCFI 会校验函数签名（type hash）。
模块里任何函数原型与内核编译时不一致，`insmod` 时立刻报：

```
CFI failure at do_one_initcall (target: init_module+0x0 [macvlan])
```

然后**直接关机**。这不是软失败，是硬 panic。

所以：

- 必须用**与目标内核匹配的 clang**。本机内核是用
  `Android (11368308, ...) clang version 18.0.0` 编译的，即 `clang-r510928`。
- 必须用匹配该 KMI 的 **KDIR**（`android15-6.6`）。
- DDK 镜像同时提供了两者：

```
docker.cnb.cool/ylarod/ddk/ddk-min:android15-6.6
  KDIR  = /opt/ddk/kdir/android15-6.6   (6.6.127-4k-g46a034eca005)
  src   = /opt/ddk/src/android15-6.6    (完整源码树)
  clang = /opt/ddk/clang/clang-r510928  (与设备原厂同一 build)
```

---

## 1. 准备 DDK 环境（两种方式）

### 方式 A：docker（原版路径）

```bash
docker pull docker.cnb.cool/ylarod/ddk/ddk-min:android15-6.6
sh scripts/build-ddkk.sh android15-6.6
```

要求 docker daemon 能正常 **run** 容器（不只是 pull）。

### 方式 B：解包 + chroot（推荐；dockerd 起不来时用这个）

> 本机实测：`dockerd` 能起、能 `pull`，但 `docker run` 卡在 `Created` 不动
> （runc 在 WSL 里起不来）。此时用解包 + chroot 完全等价。

```bash
# 1) 拉镜像（只需要能 pull）
docker pull docker.cnb.cool/ylarod/ddk/ddk-min:android15-6.6

# 2) 存成 OCI 归档
docker save docker.cnb.cool/ylarod/ddk/ddk-min:android15-6.6 -o /tmp/ddk66.tar

# 3) 解出 OCI 结构，再按 layer 顺序铺成 rootfs
mkdir -p /tmp/ddk66 && tar -xf /tmp/ddk66.tar -C /tmp/ddk66
python3 - <<'PY'
import json
m = json.load(open('/tmp/ddk66/blobs/sha256/' + open('/tmp/ddk66/index.json').read()
                   .split('"digest":"sha256:')[1].split('"')[0]))
for l in m['layers']:
    print(l['digest'].split(':')[1])
PY
# 把上面列出的 layer（注意保持顺序、跳过 mediaType=...tar+gzip 的需要先 gunzip）
```

更省事的写法（本项目实际用的）：

```bash
cd /tmp/ddk66
mkdir -p rootfs
for d in e51a2e3545f8 263b726d8bce 81f747c0a410 6a35a0fc99f3 \
         3f5f46185f86 7a1c5aed200d 0428be403ebc; do
  tar -xf blobs/sha256/${d}* -C rootfs 2>/dev/null
done
```

> layer digest 顺序取自 `blobs/sha256/<manifest>` 里的 `layers[]` 数组，
> **必须按数组顺序解**，否则文件会被旧 layer 覆盖。

得到 `/tmp/ddk66/rootfs`，就是 `DDK_ROOT`。

### 1.1 chroot 模式必须手工设的两个环境变量

DDK 镜像的 `PATH` / `LD_LIBRARY_PATH` 写在镜像 `Config.Env` 里，docker 会自动注入，
chroot 不会。少了任何一个都会失败：

| 变量 | 值 | 少了会怎样 |
|---|---|---|
| `PATH` 含 `clang` 目录 | `/opt/ddk/clang/clang-r510928/bin` | 回退到系统 gcc，报 `unrecognized argument to '-fsanitize=' option: 'kcfi'` |
| `LD_LIBRARY_PATH` | `/opt/ddk/clang/clang-r510928/lib` | `clang.real: error while loading shared libraries: libc++.so` |
| `ARCH` / `LLVM` / `CROSS_COMPILE` | `arm64` / `1` / `aarch64-linux-gnu-` | 用 x86 目标编，`fatal error: 'asm/compiler.h' file not found` |

`scripts/build-ddkk.sh` / `build-net-ddk.sh` 在 `DDK_ROOT` 模式下已经把这三组
都设好了，直接跑即可：

```bash
cd src
DDK_ROOT=/tmp/ddk66/rootfs sh scripts/build-ddkk.sh    android15-6.6
DDK_ROOT=/tmp/ddk66/rootfs sh scripts/build-net-ddk.sh android15-6.6
```

---

## 2. 编译四个主模块

```bash
cd src
DDK_ROOT=/tmp/ddk66/rootfs sh scripts/build-ddkk.sh android15-6.6
```

脚本内部等价于：

```bash
chroot /tmp/ddk66/rootfs /bin/bash -c '
  export PATH=/opt/ddk/clang/clang-r510928/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  export LD_LIBRARY_PATH=/opt/ddk/clang/clang-r510928/lib
  export ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu-
  cd /src && make VER=android15-6.6 KDIR=/opt/ddk/kdir/android15-6.6 -j$(nproc)'
```

产物在 `droid_lkm/out/android15-6.6/`：

```
droid_lkm.ko
droid_lkm_vendor.ko
droid_lkm_misc.ko
droid_lkm_pids.ko
```

> `VER` 同时决定 KMI 选择与输出目录，必须是 `android15-6.6`。

耗时参考：`-j8` 约 3~5 分钟（首次），重编增量很快。

### 2.1 依赖：为什么不用先 fetch-deps

`droid_lkm/deps/` 里已经带了四个第三方工程（KallRecon / Type_info / KernCall /
HooKern），`.sdk/builtin/vendorcompat/` 也随包附带，所以**离线可编**。
只有删掉了才需要 `sh scripts/fetch-deps.sh`。

---

## 3. 编译两个网络模块

```bash
DDK_ROOT=/tmp/ddk66/rootfs sh scripts/build-net-ddk.sh android15-6.6
```

注意 6.6 与 6.12 的 `macvlan_core.c` **不是同一份**：

| 差异 | 6.12 版本 | 6.6 版本（本项目） |
|---|---|---|
| `dev->lltx` | 有 | **没有**（6.6 用 `NETIF_F_LLTX` 在 `ALWAYS_ON_FEATURES` 里） |
| `dev->change_proto_down` | 有 | **没有**（6.6 用 `priv_flags |= IFF_CHANGE_PROTO_DOWN`） |
| `get_ts_info` 签名 | `kernel_ethtool_ts_info` | `ethtool_ts_info` + 手工 `phy_ts_info` 分支 |

所以 `src/net_macvlan/macvlan_core.c` 是**从 DDK 的 6.6.127 源码树**取的
`drivers/net/macvlan.c`，再把 shim 挂点打回去的（diff 只有 6 处）。
详细见源码顶部注释与 `git log`。

---

## 4. 打包

```bash
sh scripts/package-ksu-zip.sh
```

产物：`dist/Droidspaces-v1.0.0-6.6.zip`，zip 根目录直接是模块内容
（`module.prop` / `post-fs-data.sh` / `ko/` …），KernelSU 可直接安装。

结构：

```
Droidspaces-6.6/
├── module.prop
├── post-fs-data.sh
├── service.sh
├── uninstall.sh
├── desc.sh
├── ko/{droid_lkm,droid_lkm_vendor,droid_lkm_misc,droid_lkm_pids,macvlan,ip6table_nat}.ko
├── mirror.sh
└── webroot/index.html
```

---

## 5. 产物自检（装机前必做）

```bash
cd src/dsm/ko

# ① vermagic 是 6.6 线
for f in *.ko; do printf "%-22s " "$f"; strings "$f" | grep -m1 vermagic=; done

# ② 依赖的符号设备上全都有（需要设备 adb）
ADB=/mnt/c/Windows/System32/adb.exe
$ADB shell 'su -c "grep \" __ksymtab_\" /proc/kallsyms | sed \"s/.*__ksymtab_//\""' \
  | tr -d '\r' | sort -u > /tmp/dev_exports.txt
for f in *.ko; do aarch64-linux-gnu-nm -u $f; done | awk '{print $2}' | sort -u > /tmp/needs.txt
comm -23 /tmp/needs.txt /tmp/dev_exports.txt    # 应输出空
```

本项目实测两次都是 **0 缺失**。

---

## 6. 逐个加载（真机，务必按顺序）

**一次 insmod 六个，崩了不知道是哪个。** 每加一个都看一眼 `dmesg`。

```sh
ADB=/mnt/c/Windows/System32/adb.exe
for f in droid_lkm droid_lkm_vendor droid_lkm_misc droid_lkm_pids macvlan ip6table_nat; do
  $ADB push src/dsm/ko/$f.ko /data/local/tmp/
done

# ① 主模块（最危险，这一步崩后面全别试）
su -c 'insmod /data/local/tmp/droid_lkm.ko gate=0 mqueue=1 nspid=1 nspid_append=1 \
       skip_sysvipc=0 no_fake_ns=0 skip_do_exit=0'
su -c 'dmesg | grep droid_lkm | tail -30'   # 期望 "layout: ... ok" + "ready"

# ② vendor
su -c 'insmod /data/local/tmp/droid_lkm_vendor.ko ghost=1 ghost_match=oplus_ pid_max_cap=0'

# ③ misc（历史上最容易崩的一个）
su -c 'insmod /data/local/tmp/droid_lkm_misc.ko'

# ④ pids
su -c 'insmod /data/local/tmp/droid_lkm_pids.ko'

# ⑤ 网络
su -c 'insmod /data/local/tmp/macvlan.ko'
su -c 'insmod /data/local/tmp/ip6table_nat.ko'
```

卸载顺序**反过来**（pids 可单独卸，misc 持有 devtmpfs 内部 mount 要先放掉，
lkm 最后 —— 容器在跑时 lkm 会 `Try again`，需要先停容器）。

---

## 7. 2026-11-03 实测记录

| 项 | 结果 |
|---|---|
| 6 个 ko 编译 | ✅ 全部成功 |
| 符号缺失 | 0 |
| `insmod` 6 个 | ✅ 全部 rc=0 |
| 布局自校验 | ✅ 62 项 `live == build` |
| pid namespace | ✅ `unshare -p` 子进程 pid=1 |
| ipc namespace | ✅ `unshare -i` 成功 |
| devtmpfs | ✅ `/proc/filesystems` 有 |
| pids 显示层 | ✅ `cgroup.controllers` / `/proc/cgroups` 有 pids |
| macvlan | ✅ `ip link add type macvlan` rc=0 |
| ip6tables nat | ✅ 表可列 |
| userns | ❌ `-EINVAL`（内核未编译，预期内） |

---

## 8. 常见失败

| 现象 | 原因 | 动作 |
|---|---|---|
| `gcc: unrecognized argument to '-fsanitize=' option: 'kcfi'` | `PATH` 没指到 DDK clang | 见 §1.1 |
| `clang.real: error while loading shared libraries: libc++.so` | `LD_LIBRARY_PATH` 没设 | 见 §1.1 |
| `fatal error: 'asm/compiler.h' file not found` | 缺 `ARCH=arm64` / `LLVM=1` | 见 §1.1 |
| `CFI failure at ...` 然后关机 | clang 与内核不匹配 | 必须用 DDK 的 r510928 |
| `insmod: invalid module format` | 内核没开 `MODVERSIONS` 且首段不符 | 自建对应小版本 KDIR |
| `insmod: Unknown symbol xxx` | 符号未导出 | 补 KallRecon 自解析名单 |
| `rmmod: Try again` | 容器仍在用 pid/ipc ns | 先停容器 |
