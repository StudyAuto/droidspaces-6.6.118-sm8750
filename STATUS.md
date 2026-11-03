# 真机实测状态

> 机型：一加 13 **PJZ110 / OP5D0DL1**
> 内核：`6.6.118-android15-8-g899dc6830d9c-abogki500782043-lotus-4k`
> 系统：`PJZ110_16.0.10.501(CN01)` / Android 16
> 槽位：`_a`
> 记录时间：2026-11-04（模块加载 / 符号 CRC / userns 已更新）

本文记录的是**这台机器上跑出来的真实结果**，不是设计意图。

---

## 〇、构建基准（2026-11-04）

| 项 | 值 |
|---|---|
| 编译来源 | GitHub Actions，真实 6.6.118 源码树 |
| 符号基准 | 设备权威表 `device-6.6.118.symvers`（9116 条） |
| `module_layout` CRC | `0x4e276f37`（本地产物与设备**原生一致**） |
| 逐符号比对 | **645/645** 全部一致 |
| 交叉验证 | `boot_stats.ko` 11/11、`bam_dma.ko` 84/84 |

> 早期用 DDK 6.6.127 编的产物 CRC 大面积不符（203 个里 97 个），
> 靠「vermagic 首段被跳过」蒙混——那不是兼容，是没校验。
> 详见 [docs/KERNEL-ADAPTATION.md](docs/KERNEL-ADAPTATION.md)。

---

## 一、模块加载（全部 rc=0）

```sh
su -c 'insmod droid_lkm.ko gate=0 mqueue=1 nspid=1 nspid_append=1 skip_sysvipc=0 no_fake_ns=0 skip_do_exit=0'
su -c 'insmod droid_lkm_vendor.ko ghost=1 ghost_match=oplus_ pid_max_cap=0'
su -c 'insmod droid_lkm_misc.ko'
su -c 'insmod droid_lkm_pids.ko'
su -c 'insmod macvlan.ko'
su -c 'insmod ip6table_nat.ko'
```

```text
$ grep -E '^(droid_lkm|macvlan|ip6table_nat) ' /proc/modules
ip6table_nat     114688 0 - Live (O)
macvlan          139264 0 - Live (O)
droid_lkm_pids   454656 0 - Live (O)
droid_lkm_misc   520192 1 - Live (O)
droid_lkm_vendor 471040 0 - Live (O)
droid_lkm        684032 1 - Live (O)
```

| 模块 | 状态 | 关键日志 |
|---|---|---|
| `droid_lkm` | ✅ | `layout: ... ok live=784 build=784`、`ready` |
| `droid_lkm_vendor` | ✅ | `BTF 10/10 fields live`、`ghost: find_task_by_vpid hooked, match=oplus_` |
| `droid_lkm_misc` | ✅ | `devtmpfs: registered only (hook off)`、`userns hooks installed`、`userns ready` |
| `droid_lkm_pids` | ✅ | `layout verified: controllers=7`、`pids limit enforcement active` |
| `macvlan` | ✅ | `[macvlan-shim] self-resolved 7/7 symbols` |
| `ip6table_nat` | ✅ | 自解析成功（无回退日志） |

**布局自校验全部通过**：`droid_lkm` 输出 20 项 `live == build`，
`droid_lkm_misc` 输出 60+ 项全部 `ok`（`live == build`）。

> 2026-11-03 时这里写的是「用 6.6.127 头文件编出来的结构体偏移在 6.6.118
> 上完全一致」——这个结论**已被推翻**。布局看似一致不代表 CRC 一致，
> 而且 `__versions` 为空时内核根本不校验。详见
> [docs/KERNEL-ADAPTATION.md](docs/KERNEL-ADAPTATION.md)。

---

## 二、命名空间与 IPC（实测）

```sh
$ su -c 'unshare -p -f /system/bin/sh -c "echo mypid=$$"'
mypid=1                 ### ✅ pid namespace 生效（子进程 pid 变 1）

$ su -c 'unshare -i /bin/sh -c "echo IPCNS_OK"'
IPCNS_OK                ### ✅ IPC namespace 生效

$ su -c 'unshare -m -p -i -u /bin/sh -c "echo NS_OK"'
NS_OK                   ### ✅ mnt/pid/ipc/uts 组合可用

$ su -c 'ls /proc/1/ns/'
cgroup mnt net time time_for_children uts    ### 无 user —— 内核没编译 userns
```

---

## 三、devtmpfs

```sh
$ grep devtmpfs /proc/filesystems
nodev	devtmpfs      ### ✅ 已注册
```

模块日志说明它是**只注册、不开 hook**：

```text
[droid_lkm_misc] devtmpfs: mount ok
[droid_lkm_misc] devtmpfs: registered only (hook off).
                 mount -t devtmpfs works; nodes need userland mknod
```

---

## 四、pids 控制器

### 显示层 ✅

```sh
$ cat /sys/fs/cgroup/cgroup.controllers
pids
$ cat /proc/cgroups
pids	0	1	1        ### ✅ 内核列表里出现 pids
```

### 功能层 ⚠️ 待容器实测

```text
[droid_lkm_pids_ctl] layout verified: controllers=7 (built against 7)
[droid_lkm_pids_ctl] probed cgroup_can_fork  at 0xffffffec321c2d40
[droid_lkm_pids_ctl] pids limit enforcement active (emulated pids controller)
```

功能层的 `pids.max` / `pids.current` / `pids.stats` 挂在 **memory 子系统**上
（`cgroup_add_dfl_cftypes(memory_ss, ...)`），所以只在 Droidspaces 真正建出
带 memory 控制器的容器 cgroup 后才会出现。**手工 mkdir 的 cgroup 看不到这三个文件**：

```sh
$ mkdir /sys/fs/cgroup/t1 && ls /sys/fs/cgroup/t1 | grep pids
（空）                    ### 正常 —— 这是 cgroup2 根，没挂 memcg 文件
```

判据（容器起来后）：

```sh
su -c 'cat /sys/fs/cgroup/<容器目录>/pids.stats'
# refused > 0 即功能层生效
```

---

## 五、网络扩展

```sh
$ su -c 'ip link add mvtest0 link wlan0 type macvlan mode bridge; echo $?'
0                        ### ✅ macvlan 能建接口

$ su -c 'ip6tables -t nat -L -n'
Chain PREROUTING (policy ACCEPT)     ### ✅ nat 表可注册/可列
```

⚠ 与 6.12 那台同样的限制：这台机的 WiFi 驱动只认一个 MAC，macvlan 接口能建
但收发不通（TX 涨 RX 恒 0）。真正要用需要 USB 有线网卡。

---

## 五之二、容器内 Docker（2026-11-03 新增，已验证可跑容器）

前提：Droidspaces App v7.1.0 + 容器（Ubuntu 24.04）+ `docker.io 29.1.3`。

**`docker run` 成功**，但这台机器上必须同时满足三个条件，缺一个就失败，
且失败信息都不指向真正原因：

| # | 条件 | 不满足时 |
|---|---|---|
| 1 | runc 用 **1.1.15**（Ubuntu 24.04 自带的是 1.3.4） | `unsafe procfs detected: ... proc/self/setgroups: no such file or directory` |
| 2 | `storage-driver = vfs` | `overlay: case-insensitive capable filesystem on ... not supported` |
| 3 | iptables 用 **legacy** 后端 | `iptables v1.8.10 (nf_tables): Could not fetch rule set generation id` |

实测：

```text
$ docker info
 Server Version: 29.1.3
 Storage Driver: vfs
 Cgroup Version: 2

$ docker run --rm --runtime=runc115 hello-world
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

### 为什么必须用旧版 runc

内核没有 `CONFIG_USER_NS` → 容器内 `/proc/self/setgroups` 不存在。
runc **1.3.x** 把「procfs 缺 setgroups」判定为不可信并直接拒绝创建容器；
**1.1.15 没有这道检查**，正常启动。这是 runc 自己新加的硬化，不是内核能力缺失。

> 我一开始归因成「内核缺 userns 所以 Docker 跑不了」，方向是错的。
> 用最小 OCI spec 手工 `runc run` 也失败，一度加深了误判；
> 换成标准 `runc spec`（自带 /proc /dev /dev/pts /dev/shm /sys 五个挂载）后能过，
> 说明手工最小 spec 本身有缺陷，不能当判据。

### 一键脚本

`src/dsm/tools/setup-docker.sh`（打包后位于模块 `tools/` 下），在**容器内**执行：

```sh
sh /data/adb/modules/Droidspaces-6.6/tools/setup-docker.sh check   # 只检查
sh /data/adb/modules/Droidspaces-6.6/tools/setup-docker.sh         # 全套：装 runc + 切 iptables + 写 daemon.json + 起 dockerd + 跑 hello-world
```

实测输出：

```text
[docker-setup] 架构: aarch64
[docker-setup] CONFIG_USER_NS: n  (n → 必须用 runc 1.1.x)
[docker-setup] overlay on /data:  unavailable
[docker-setup] iptables 后端:     iptables v1.8.10 (legacy)
[docker-setup] runc 1.1.15:       runc version 1.1.15
...
[docker-setup] ✅ Docker 可用
```

完整教程见 [`docs/tutorials/04-docker.md`](docs/tutorials/04-docker.md)。

---

## 六、user namespace（模块侧 ready，隔离待容器实测）

### 内核侧的事实（不会变）

| # | 观测 | 命令 |
|---|---|---|
| 1 | `# CONFIG_USER_NS is not set` | `zcat /proc/config.gz \| grep USER_NS` |
| 2 | `/proc/self/ns/` 里没有 `user` | `ls /proc/self/ns/` |
| 3 | `/proc/self/uid_map` 不存在 | `cat /proc/self/uid_map` → No such file |

内核没编 `CONFIG_USER_NS`，`unshare(CLONE_NEWUSER)` 在内核里直接返回 `-EINVAL`。
模块无法改变这一点，只能自建一套 fake userns 兜底。

**`/proc/sys/user/max_user_namespaces` 有值不代表支持 userns**，别拿它当证据。

### 模块侧：2026-11-04 修复后 ready

```sh
$ grep '^userns ' /proc/droid_lkm_misc/status
userns                   ready          unshare clone namespace entry credential swap
userns view              armed          18 armed 0 missing real=0
userns id map files      ready          uid_map gid_map setgroups under /proc/<pid>
```

> ⚠️ **2026-11-03 的旧结论「结案：不可用」是错的。**
> 当时的证据是 `dmesg` 里的 `userns unavailable: -22`，被误读成
> 「内核没编 `CONFIG_USER_NS`」。真实原因是模块自己的 bug：
> `is_text()` 用 8 字节对齐校验 arm64 的 4 字节对齐函数入口
> （`mntns_owner=...f53c`），`mntns_operations` 被判非法 → 整个 userns
> 初始化失败。修正为按指令宽度判后即可正常初始化。
> 详见 [docs/KERNEL-ADAPTATION.md](docs/KERNEL-ADAPTATION.md) §8。

### 状态语义

| 模块状态 | 含义 | WebUI 开关 |
|---|---|---|
| `ready` | 模块的 fake userns 路径已就绪 | ✅ 启用 |
| `unsupported` | 符号解析或挂接失败 | ❌ 禁用 + 显示原因 |
| `off` | 加载时传了 `userns=0` | ❌ 禁用 |

> **`ready` 只表示模块侧路径打通，不等于「容器 root 与宿主 root 已隔离」。**
> fake userns 不是内核 userns，隔离效果需容器侧单独验证。

### 关于 selftest 的 `-22`

```sh
$ grep '^userns selftest' /proc/droid_lkm_misc/status
userns selftest          failed         1 failed: unshare(CLONE_NEWUSER) (-22)
```

这是**策略默认值**，不是故障：自检进程名 `dlm_userns_prob` 既不「已在
namespace 内」也不「从 root 启动」，而 `userns_any` 默认关闭。
dmesg 会写明 `refused, userns_any is off`。
想跑通完整自检需 `insmod droid_lkm_misc.ko userns_any=1`
（`droid_lkm` 被 proc ns hook 永久 pin，改参数只能重启后重载）。

> **注意宿主和容器的 `/proc/config.gz` 不是同一份：**
>
> | 位置 | 值 | 说明 |
> |---|---|---|
> | 宿主 | `CONFIG_USER_NS=y` | `tools/fake_config.sh` 伪装（tmpfs + `context=config_gz`），为骗过 App 探测 |
> | 容器内 | `# CONFIG_USER_NS is not set` | 容器有自己的 `/proc`，这是真实内核配置 |
>
> 模块状态的 `unsupported` 与容器内那份一致。宿主侧的 `y` 不能当判据。
> （`umount /proc/config.gz` 也能在宿主上看到真实值，但下次服务重启会被重新伪装。）
>
> ⚠️ **伪装文件的 SELinux 类型必须与真文件一致（`config_gz`）**，否则 `system_server`
> 读不到会 SIGABRT 导致整机重启 —— v1.0.0 真实踩过。v1.0.1 改用 tmpfs 的
> `context=` 设置类型，并加了挂载前后双验证与回滚。详见
> [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) ⑤。

---

## 七、设备配置快照（决定要补什么）

```text
# CONFIG_PID_NS is not set          # CONFIG_IPC_NS is not set
# CONFIG_SYSVIPC is not set          # CONFIG_POSIX_MQUEUE is not set
# CONFIG_USER_NS is not set          # CONFIG_DEVTMPFS is not set
# CONFIG_CGROUP_PIDS is not set      # CONFIG_CGROUP_DEVICE is not set
# CONFIG_MACVLAN is not set          # CONFIG_IP6_NF_NAT is not set
# CONFIG_NF_TABLES is not set        # CONFIG_BRIDGE_NETFILTER is not set
# CONFIG_IP_SET is not set           # CONFIG_CHECKPOINT_RESTORE is not set

CONFIG_NET_NS=y   CONFIG_UTS_NS=y   CONFIG_TIME_NS=y   CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y  CONFIG_CGROUP_FREEZER=y  CONFIG_CGROUP_CPUACCT=y
CONFIG_BRIDGE=y   CONFIG_VETH=y   CONFIG_OVERLAY_FS=y   CONFIG_FUSE_FS=y
CONFIG_SECCOMP=y  CONFIG_SECCOMP_FILTER=y  CONFIG_KEYS=y  CONFIG_ZRAM=m

CONFIG_CFI_CLANG=y        CONFIG_MODVERSIONS=y      CONFIG_TRIM_UNUSED_KSYMS=y
CONFIG_MODULE_SIG=y       CONFIG_MODULE_SIG_FORCE 未设（可加载未签名 ko）
CONFIG_MODULE_FORCE_LOAD 未设
CONFIG_LTO_NONE=y         CONFIG_ANDROID_KABI_RESERVE=y
```

---

## 八、已知边界

| 边界 | 原因 | 能不能改 |
|---|---|---|
| 容器 root = 宿主 root | 无 userns | ❌ 内核没编译 |
| `--pids-limit` 建议 ≥ 256 | 空跑容器自身约 68 进程 | ⚙️ config |
| 无 `NF_TABLES` / `IP_SET` | 内核未编译 | ⚠️ 需要时才补 |
| 无 `BRIDGE_NETFILTER` | 内核未编译 | ⚠️ bridge 网络受限 |
| 卸载 `droid_lkm` 需等引用计数归零 | pid/ipc ns 对象仍被容器持有 | ⚙️ 先停容器 |

---

## 九、验证命令速查

```sh
ADB=/mnt/c/Windows/System32/adb.exe

$ADB shell 'su -c "grep -E \"^(droid_lkm|macvlan|ip6table_nat) \" /proc/modules"'
$ADB shell 'su -c "unshare -p -f /system/bin/sh -c \"echo pid=\\\$\\\$\""'
$ADB shell 'su -c "grep devtmpfs /proc/filesystems"'
$ADB shell 'su -c "cat /sys/fs/cgroup/cgroup.controllers"'
$ADB shell 'su -c "ip link add t0 link wlan0 type macvlan mode bridge && ip link del t0"'
$ADB shell 'su -c "dmesg | grep -iE \"droid_lkm|macvlan-shim\""'
```
