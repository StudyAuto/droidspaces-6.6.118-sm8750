# Droidspaces 6.6 for SM8750（一加 13 / OP5D0DL1）

在**原厂 GKI 内核**（不刷内核、不改 App 源码）上补齐 Docker / 容器运行时缺失的内核能力的 KernelSU 模块合集。

目标机型：**一加 13（PJZ110 / OP5D0DL1）**，内核
`6.6.118-android15-8-g899dc6830d9c-abogki500782043-lotus-4k`

```
当前版本   v1.0.1-6.6
状态       ✅ 6 个模块真机加载成功（2026-11-04）
内核基线   6.6.118-android15-8（KMI android15-6.6）
编译来源   GitHub Actions：真实 6.6.118 源码树 + clang r510928
符号基准   设备权威 CRC（从 boot_a 提取，645/645 逐符号对齐）
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
| **user namespace** | 模块自建 fake userns + id 翻译 | ⚠️ 模块就绪，隔离待容器实测 |

---

## ⚠️ 必读：`CONFIG_USER_NS` 的真实状态

设备内核**编译时就没有 `CONFIG_USER_NS`**，模块无法在运行时把它变出来：
`unshare(CLONE_NEWUSER)` 在内核里直接返回 `-EINVAL`。

```sh
$ su -c 'zcat /proc/config.gz | grep USER_NS'
# CONFIG_USER_NS is not set
$ ls /proc/self/ns/
cgroup mnt net time time_for_children uts    # 没有 user
```

**模块的应对**：`droid_lkm_misc.ko` 自带一套 fake userns + id 翻译层。
它不是内核 userns，而是：

- 在 `unshare` / `clone` 路径上接受 `CLONE_NEWUSER`
- 自建 `user_namespace` 对象与 `/proc/<pid>/{uid_map,gid_map,setgroups}`
- 在 syscall 边界翻译 uid/gid（真降权 + 读回映射）

**当前状态**：模块侧 `userns ready`（`/proc/droid_lkm_misc/status`），
18 个 view 探针 armed、0 missing。**但容器侧的真隔离效果尚未完整实测**，
不要当成「等同内核 CONFIG_USER_NS」。

```sh
# 唯一可信的判定
su -c 'grep "^userns " /proc/droid_lkm_misc/status'
# userns  ready  unshare clone namespace entry credential swap   ← 模块就绪
# userns  unsupported  owner symbols missing                     ← 没修通
```

> 2026-11-04 修了一个真 bug：`is_text()` 用 8 字节对齐校验 arm64 的
> 4 字节对齐函数入口，导致 `mntns_operations` 解析失败、userns 整体降级。
> 详见 [`docs/KERNEL-ADAPTATION.md`](docs/KERNEL-ADAPTATION.md) §8。

原理见 [`docs/PRINCIPLE.md`](docs/PRINCIPLE.md)。

---

## 设备实测缺口（2026-11-04）

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
| `CONFIG_USER_NS` | **n** | 模块自建 fake userns（不能真隔离内核对象） |
| `CONFIG_NET_NS` / `OVERLAY_FS` / `VETH` / `BRIDGE` / `SECCOMP` | y | 无需补 |
| `CONFIG_CFI_CLANG` | **y** | ⚠️ 编译器必须匹配 |
| `CONFIG_MODVERSIONS` | **y** | ⚠️ 每个导入符号的 CRC 必须与设备一致 |
| `CONFIG_DEBUG_INFO_BTF_MODULES` | **y** | ⚠️ 编译时必须真开，否则 `module_layout` CRC 错 |
| `CONFIG_TRIM_UNUSED_KSYMS` | **y** | 未导出符号要用 KallRecon 自解析；编译时须关闭 |

---

## 符号 CRC：模块能否加载的唯一关卡

> ⚠️ **本节是 2026-11-04 修正后的结论。**
> 早期版本写过「用 DDK 6.6.127 编的模块能进 6.6.118，不用自建 KDIR」——
> **那是错的，已作废。**

内核在 `insmod` 时对模块导入的**每一个符号**比对 CRC：

```
disagrees about version of symbol module_layout
```

只要有一个不符就拒绝加载。CRC 由 `genksyms` 按**头文件声明文本 + 配置**算出，
所以必须让编译环境与设备内核尽可能一致。

### 两个必踩的坑

**① `CONFIG_DEBUG_INFO_BTF_MODULES` 被静默关掉（最常见）**

CI 缺 `pahole` 时 `olddefconfig` 会自动关闭 `DEBUG_INFO_BTF*`（它是依赖项，
不是显式配置项）。后果：`struct module` 少 `btf_data`/`btf_data_size` 两个字段，
中间成员整体位移 **48 字节**。因为末尾有 `android_kabi_reserved1..4` 垫着，
**`sizeof` 完全不变**——只看大小根本发现不了，只有 CRC 会变。

修法：装 `pahole`（Ubuntu 24.04 自带 1.25，与设备 `CONFIG_PAHOLE_VERSION=125` 一致），
并在 `olddefconfig` **之后**硬断言这两项为 `y`。

**② 设备内核是第三方 fork，源码文本有漂移**

设备 commit `899dc6830d9c` 不在上游仓库，头文件声明文本不同 → CRC 不同。
所以即便配置一致，本地方案也复现不出设备真值。

修法：用**设备权威符号表**兜底。

### 设备权威符号表怎么来

不需要在设备上跑任何内核代码，直接读 `boot_a` 里的 `vmlinux`：

```sh
adb shell 'dd if=/dev/block/by-name/boot_a of=/data/local/tmp/boot_a.img bs=1M'
adb pull /data/local/tmp/boot_a.img
```

内核是未压缩的原生 `Image`（`ARMd` 魔数），从中解析
`__ksymtab` / `__ksymtab_gpl` / `__kcrctab` 得到 9116 条符号 + CRC，
产出 `.github/symvers/device-6.6.118.symvers`。

**必须交叉验证**：拿设备真实 vendor 模块的 `__versions` 反查，
`boot_stats.ko` 11/11、`bam_dma.ko` 84/84 全中才算对。

### 出货闸门

```sh
python3 .github/scripts/check-symvers.py \
  .github/symvers/device-6.6.118.symvers src/dsm/ko/*.ko
```

逐条比对，全绿才装机。2026-11-04 实测：**645/645 全部一致**。

> 完整方法论（含换内核/换机型的清单、排查表、以及三次失败的探针方案）
> 见 **[docs/KERNEL-ADAPTATION.md](docs/KERNEL-ADAPTATION.md)**。

---

## 目录结构

```
.
├── README.md                  ← 你在这里
├── STATUS.md                  ← 真机实测状态
├── CHANGELOG.md               ← 版本历史
├── .github/
│   ├── workflows/
│   │   └── build-lkm-6.6.118.yml   主线构建（Actions）
│   ├── kconfig/
│   │   └── device-6.6.118.config   设备 /proc/config.gz 快照
│   ├── symvers/
│   │   └── device-6.6.118.symvers  设备权威符号表（9116 条 CRC）
│   ├── scripts/
│   │   ├── merge-symvers.py        合并设备表（冲突时设备优先）
│   │   └── check-symvers.py        出货闸门：逐符号比对 CRC
│   └── probe/                      CRC 探针（历史，已被 boot 解析取代）
├── docs/
│   ├── KERNEL-ADAPTATION.md   ★ 换内核 / 换机型 / 重编译 必读
│   ├── BUILD.md               构建（Actions 主线 + DDK 备选）
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

**主线：GitHub Actions**（推荐，换内核后重编也走这条）

```sh
git push                      # 触发 .github/workflows/build-lkm-6.6.118.yml
```

流程：拉真实 6.6.118 源码 → 用设备 config 编内核 → 合并设备权威符号表 →
编 6 个模块 → 逐符号 CRC 闸门 → 上传 artifact。

**备选：本地 DDK**（Actions 不可用时）

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

**编完必须先过闸门再装机**——CRC 不符的 ko 装上去只会 `insmod` 失败：

```sh
python3 .github/scripts/check-symvers.py \
  .github/symvers/device-6.6.118.symvers src/dsm/ko/*.ko
```

---

## 安装

1. KernelSU → 模块 → 安装 `release/v1.0.1/Droidspaces-v1.0.1-6.6.zip` → 重启
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
| 内核无真 userns | `CONFIG_USER_NS` 未编译 | ⚠️ 模块自建 fake userns 兜底，非等价 |
| Docker 不能用 overlay2 | `/data` f2fs + casefold | ❌ 要刷内核 |
| Docker 不能用 nft | 无 `CONFIG_NF_TABLES` | ❌ 要刷内核 |
| Docker 必须用旧版 runc | 无内核 userns 时 1.3.x 会拒绝 | ✅ 已用 1.1.15 绕过 |
| `--pids-limit` 需 ≥ 256 | 空跑容器自身要 ~68 进程 | ⚙️ 配置 |
| `net_mode=host` 下无网络隔离 | 没有 `BRIDGE_NETFILTER` | ⚠️ 改 bridge 要 macvlan 配合 |
| 容器 root = 宿主 root | 无真 userns，id 翻译非隔离边界 | ⚠️ 待容器实测 |

---

## 换内核 / 换机型

**先读 [`docs/KERNEL-ADAPTATION.md`](docs/KERNEL-ADAPTATION.md)。**

一句话：模块能否加载 100% 取决于**符号 CRC 是否与设备内核一致**。

必须按顺序做四件事，任一步跳过都会踩坑：

1. **取设备配置** — `zcat /proc/config.gz`，`tr -d '\r'`
2. **取设备权威符号表** — 从 `boot_a` 镜像解析，**不在设备上跑内核代码**
3. **交叉验证** — 用 2 个 vendor ko 的 `__versions` 反查，必须 100% 命中
4. **编内核 + 合并 symvers + 过闸门**

前置依赖：`pahole` 必装。它缺失会让 `olddefconfig` 静默关掉
`CONFIG_DEBUG_INFO_BTF_MODULES`，导致 `struct module` 中间字段位移 48 字节
（`sizeof` 不变，极难发现），`module_layout` CRC 必错。

```sh
# 换内核后必跑
python3 .github/scripts/check-symvers.py \
  .github/symvers/device-<新版本>.symvers src/dsm/ko/*.ko
```
