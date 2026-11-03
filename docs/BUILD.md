# 从源码到 .ko 的完整构建流程

本文档记录从零到产出 6 个 ko 的**全部**步骤，可复现。

**两条路线，按场景选：**

| 路线 | 适用 | 入口 |
|---|---|---|
| **GitHub Actions**（当前主线） | 换内核 / 换机型 / 日常重编译 | `.github/workflows/build-lkm-6.6.118.yml` |
| 本地 DDK | 只在 Actions 不可用时 | 本文 §1 起 |

> ⚠️ 无论走哪条，**符号 CRC 一致性**都是决定成败的唯一关卡。
> 取设备权威符号表、合并、出货闸门的完整方法论见
> **[KERNEL-ADAPTATION.md](KERNEL-ADAPTATION.md)**，先读它再动手。

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
```

```bash
# ② 导入符号的 CRC 与设备权威表逐个一致（需要 .github/symvers/device-*.symvers）
python3 ../../.github/scripts/check-symvers.py \
  ../../.github/symvers/device-6.6.118.symvers *.ko
```

**② 才是决定能否加载的那一关。** 内核在 `insmod` 时是**逐符号比对 CRC** 的，
只要一个不符就 `disagrees about version of symbol xxx` 并拒绝加载。

旧版这里用 `grep __ksymtab_` 只检查「符号存在」，**查不出 CRC 不符**，
已废弃——那次就是因此漏掉了 `module_layout` 不匹配。

> 设备符号表怎么来的、CRC 为什么会不一致、换内核要怎么做，
> 全部流程见 **[KERNEL-ADAPTATION.md](KERNEL-ADAPTATION.md)**。

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

## 7. 实测记录

### 2026-11-04（GitHub Actions + 设备权威 CRC，当前基线）

| 项 | 结果 |
|---|---|
| 6 个 ko 编译 | ✅ 全部成功 |
| 逐符号 CRC 比对 | ✅ 645/645 与设备一致 |
| `insmod` 6 个 | ✅ 全部 rc=0 |
| 布局自校验 | ✅ 60+ 项 `live == build` |
| userns 初始化 | ✅ `userns ready`（修复前是 `unsupported`） |
| userns view | ✅ `armed 18 armed 0 missing real=0` |
| userns selftest | ⚠️ `unshare(CLONE_NEWUSER) -22`（策略默认值，见下） |

关键修复一：CI 装 `pahole` 后 `CONFIG_DEBUG_INFO_BTF_MODULES` 不再被
`olddefconfig` 静默关闭，`module_layout` CRC 从 `0x6500052f` 自动变成设备要的
`0x4e276f37`，**全部导入符号自动对齐，无需手改任何一个**。

关键修复二：userns 此前报 `-EINVAL`，根因**不是**「内核未编译」，
而是 `is_text()` 拿 8 字节对齐去校验 4 字节对齐的 arm64 函数入口
（`mntns_owner=...f53c`）。已在 `userns_owner.c` 修正为按指令宽度判，
详见 [KERNEL-ADAPTATION.md §8](KERNEL-ADAPTATION.md)。

上机实测的修复前后对比：

```text
修复前 dmesg:  mntns_operations unusable: -22
               userns unavailable: -22
修复前 status: userns  unsupported  owner symbols missing

修复后 dmesg:  userns hooks installed
               userns map selftest passed
               userns view: 18 armed, 0 unavailable, real=0
               userns ready
修复后 status: userns  ready  unshare clone namespace entry credential swap
```

> `CONFIG_USER_NS is not set` 仍然成立——模块的 fake userns 本来就是用来
> 替代内核功能的。修好对齐后 `mntns_operations` 能正常解析，
> 这条路径才真正可用。

**关于 selftest 的 `-22`**：这是**策略默认值**导致的，不是故障。
模块自检会在初始化时用进程名 `dlm_userns_prob` 试一次
`unshare(CLONE_NEWUSER)`，而 `userns_any` 默认为 0（只服务「已在
namespace 内」或「从 root 启动」的任务），自检进程两者都不满足，
于是被拒。dmesg 会明确写出 `refused, userns_any is off`。

想跑通完整自检，需带 `userns_any=1` 加载：

```sh
insmod droid_lkm_misc.ko userns_any=1
```

> 但 `droid_lkm` 被 proc ns hook 永久 pin（`ds_proc.c:308` 的
> `try_module_get`），要改参数只能重启后重新加载。

### 2026-11-03（本地 DDK）

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
| userns | ❌ `-EINVAL`（当时误判为「内核未编译」，实为对齐 bug） |

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
