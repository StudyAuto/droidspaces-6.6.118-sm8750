# Droidspaces 6.6 for SM8750（一加 13 / OP5D0DL1）

在**原厂 GKI 内核**（不刷内核、不改 App 源码）上补齐 Docker / 容器运行时缺失的内核能力的 KernelSU 模块合集。

目标机型：**一加 13（PJZ110 / OP5D0DL1）**，内核
`6.6.118-android15-8-g899dc6830d9c-abogki500782043-lotus-4k`

```
当前版本   v1.0.0-6.6
状态       ✅ 6 个模块真机加载成功（2026-11-03）
内核基线   6.6.118-android15-8（KMI android15-6.6）
编译来源   DDK android15-6.6（clang r510928，与设备原厂同版本）
```

> 这是 [`droidspaces-6.12-pmb110`](../droidspaces-6.12-pmb110) 的 6.6 分支移植。
> 6.12 那套的结论（尤其是 user namespace 补不了）在 6.6 上同样成立。

---

## 一分钟了解

| 能力 | 做法 | 状态 |
|---|---|---|
| **PID namespace** | `droid_lkm.ko` 运行时补 `CONFIG_PID_NS` | ✅ 已验证（子进程 pid=1） |
| **IPC / mqueue** | `droid_lkm.ko` 补 `CONFIG_IPC_NS` / `CONFIG_SYSVIPC` / `CONFIG_POSIX_MQUEUE` | ✅ 已验证（`unshare -i` 通） |
| **devtmpfs** | `droid_lkm_misc.ko` 注册同名文件系统 | ✅ 已验证（`/proc/filesystems` 有） |
| **pids 控制器** | `droid_lkm_pids.ko`，让 `--pids-limit` 真正生效 | ✅ 已加载（显示层已验证） |
| **macvlan / IPv6 NAT** | 独立模块，容器独立 IP | ✅ 已验证（可建接口、nat 表可列） |
| **user namespace** | ~~伪造 userns~~ | ❌ **做不到，已结案** |

---

## ⚠️ 必读：`CONFIG_USER_NS` 补不了

设备内核**编译时就没有 `CONFIG_USER_NS`**，模块无法在运行时补出来。本机实测：

```sh
$ su -c 'zcat /proc/config.gz | grep USER_NS'
# CONFIG_USER_NS is not set
$ ls /proc/self/ns/
cgroup mnt net time time_for_children uts    # 没有 user
```

**后果**：容器 root **就是**宿主 root。`droid_lkm_misc.ko` 那套 id 翻译钩子会加载
但**翻译是恒等的**，不产生任何隔离。

详见 [`docs/PRINCIPLE.md`](docs/PRINCIPLE.md)。

---

## 设备实测缺口（2026-11-03）

`zcat /proc/config.gz` 的分组结果，决定了这套模块要补什么：

| 配置 | 设备值 | 谁补 |
|---|---|---|
| `CONFIG_PID_NS` | **n** | `droid_lkm.ko` |
| `CONFIG_IPC_NS` | **n** | `droid_lkm.ko` |
| `CONFIG_SYSVIPC` | **n** | `droid_lkm.ko` |
| `CONFIG_POSIX_MQUEUE` | **n** | `droid_lkm.ko` |
| `CONFIG_DEVTMPFS` | **n** | `droid_lkm_misc.ko` |
| `CONFIG_CGROUP_PIDS` | **n** | `droid_lkm_pids.ko` |
| `CONFIG_MACVLAN` | **n** | `macvlan.ko` |
| `CONFIG_IP6_NF_NAT` | **n** | `ip6table_nat.ko` |
| `CONFIG_USER_NS` | **n** | ❌ 补不了 |
| `CONFIG_NET_NS` / `OVERLAY_FS` / `VETH` / `BRIDGE` / `SECCOMP` | y | 无需补 |
| `CONFIG_CFI_CLANG` | **y** | ⚠️ 编译器必须匹配 |
| `CONFIG_MODVERSIONS` | **y** | 让 6.6.127 的 ko 能进 6.6.118 |
| `CONFIG_TRIM_UNUSED_KSYMS` | **y** | 未导出符号要用 KallRecon 自解析 |

---

## 为什么用 DDK 的 6.6.127 编的模块能进 6.6.118

这是本项目最关键的一条，**不用自建 6.6.118 KDIR**：

1. 设备 `CONFIG_MODVERSIONS=y` → 模块带 `__versions` crc 段
2. 内核 `same_magic(amagic, bmagic, has_crcs)`：
   ```c
   if (has_crcs) { amagic += strcspn(amagic, " "); bmagic += strcspn(bmagic, " "); }
   return strcmp(amagic, bmagic) == 0;
   ```
   **首段（`6.6.127-4k-g...`）被跳过，只比较空格后的
   `SMP preempt mod_unload modversions aarch64`**
3. clang 版本必须一致：DDK 镜像里的 `clang-r510928` 与设备原厂编译内核用的是
   **同一个 build** `Android (11368308, ...) clang version 18.0.0`，所以 KCFI
   哈希天然匹配

真机验证：

```text
hello: no symbol version for module_layout
hello-probe: loaded          ← insmod rc=0，没有 vermagic 拒绝
```

⚠ 若目标内核不开 `CONFIG_MODVERSIONS`，这条不成立，必须自建对应 KDIR。

---

## 目录结构

```
.
├── README.md                  ← 你在这里
├── STATUS.md                  ← 真机实测状态
├── docs/
│   ├── BUILD.md               构建（DDK 解包 / chroot / 产物校验）
│   ├── PRINCIPLE.md           原理
│   ├── PIDS-ENFORCEMENT.md    pids 功能层
│   ├── TROUBLESHOOTING.md     踩坑记录
│   └── tutorials/             1~6 篇用法，07 移植
└── src/
    ├── droid_lkm/             4 个主模块的 C 源码
    ├── dsm/                   主模块的 KernelSU 包（脚本 + WebUI）
    │   └── tools/             action / fake_config / setup-docker
    ├── dsm-pids/              pids 独立包
    ├── net_macvlan/           网络扩展
    ├── net_ip6nat/
    └── scripts/               build-ddkk.sh / build-net-ddk.sh / package-ksu-zip.sh
```

---

## 构建

```sh
cd src

# 方式 A：本机 chroot（推荐，无需 docker daemon）
DDK_ROOT=/path/to/ddk-rootfs sh scripts/build-ddkk.sh     android15-6.6
DDK_ROOT=/path/to/ddk-rootfs sh scripts/build-net-ddk.sh  android15-6.6

# 方式 B：docker（需要能起容器的 docker daemon）
sh scripts/build-ddkk.sh    android15-6.6
sh scripts/build-net-ddk.sh android15-6.6

# 打包
sh scripts/package-ksu-zip.sh
```

`DDK_ROOT` 是 `docker.cnb.cool/ylarod/ddk/ddk-min:android15-6.6` 解包后的
rootfs 根目录（见 [`docs/BUILD.md`](docs/BUILD.md) §1）。

产物：

```
src/dsm/ko/{droid_lkm,droid_lkm_vendor,droid_lkm_misc,droid_lkm_pids,macvlan,ip6table_nat}.ko
```

---

## 安装

1. KernelSU → 模块 → 安装 `dist/Droidspaces-v1.0.0-6.6.zip` → 重启
2. 首次安装**默认关闭开机自启**（包内 `no_boot`），先手动点「加载」验证
3. 确认容器能起、`su` 正常、`apt` 可用
4. 一切正常再回 WebUI 打开「开机自动加载」

---

## 单一模块替换

```sh
su -c 'droidspaces --config=... stop
       rmmod droid_lkm_pids
       cp /sdcard/Download/droid_lkm_pids.ko /data/adb/modules/Droidspaces-6.6/ko/
       insmod /data/adb/modules/Droidspaces-6.6/ko/droid_lkm_pids.ko'
```

详见 [`src/USAGE.md`](src/USAGE.md)。

---

## 容器里跑 Docker（已验证）

`docker run` 能真正跑起来，但必须同时满足三条 —— 缺一条报错都不指向真正原因：

| # | 条件 | 不满足时 |
|---|---|---|
| 1 | runc **1.1.15**（不是 1.3.x） | `unsafe procfs detected: ... setgroups: no such file or directory` |
| 2 | `storage-driver = vfs` | `overlay: case-insensitive capable filesystem ... not supported` |
| 3 | iptables **legacy** 后端 | `iptables (nf_tables): Could not fetch rule set generation id` |

一键脚本（在容器内执行）：

```sh
sh /data/adb/modules/Droidspaces-6.6/tools/setup-docker.sh
```

实测：

```text
$ docker run --rm --runtime=runc115 hello-world
Hello from Docker!
```

详见 [`docs/tutorials/04-docker.md`](docs/tutorials/04-docker.md)。

> 第 1 条最容易误判：内核没有 `CONFIG_USER_NS` 导致 `/proc/self/setgroups` 缺失，
> 但**拦住 Docker 的是 runc 1.3 的新检查**，换 1.1.15 就过。这不是内核能力缺失。

---

## 已知边界

| 边界 | 原因 | 能不能改 |
|---|---|---|
| 容器 root = 宿主 root | `CONFIG_USER_NS` 未编译 | ❌ |
| Docker 不能用 overlay2 | `/data` f2fs + casefold | ❌ 要刷内核 |
| Docker 不能用 nft | 无 `CONFIG_NF_TABLES` | ❌ 要刷内核 |
| Docker 必须用旧版 runc | 无 userns 时 1.3.x 会拒绝 | ✅ 已用 1.1.15 绕过 |
| `--pids-limit` 需 ≥ 256 | 空跑容器自身要 ~68 进程 | ⚙️ 配置 |
| `net_mode=host` 下无网络隔离 | 没有 `BRIDGE_NETFILTER` | ⚠️ 改 bridge 要 macvlan 配合 |
| 内核 6.6.118 之外未验证 | 只测了 OP5D0DL1 | ⚠️ 换机先看 BUILD-FOR-OTHERS |
