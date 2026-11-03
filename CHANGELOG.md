# CHANGELOG

本项目是 [`droidspaces-6.12-pmb110`](../droidspaces-6.12-pmb110) 的 **6.6 分支移植**。
6.12 那边的版本历史（v1.0.0 ~ v1.0.20）不适用于本分支 —— 那些 ko 的 vermagic 是
`6.12.76`、结构体布局按 6.12 编译，在 6.6.118 上会 `Invalid module format` 或布局校验失败。

---

## v1.0.1-6.6 — 2026-11-03

**安全修复：`/proc/config.gz` 伪装会导致 system_server 崩溃、整机重启。**

### 修复（严重，必须升级）

- **`fake_config.sh`：伪装文件的 SELinux 类型错误**
  - 现象：开机后 system_server 反复 SIGABRT、整机重启、所有应用被杀
  - 崩溃信息：`Check failed: result == OK Kernel configs could not be fetched.
    b/151092221`，栈顶是 `Debug.isVmapStack` ← `MemInfoReader.getKernelUsedSizeKb`
    ← `AppProfiler.updateCachedAppsSnapshot`
  - 根因：旧版把 `/data/adb` 下的文件直接 bind 到 `/proc/config.gz`，那个文件的
    SELinux 类型是 `adb_data_file`，而真文件是 `config_gz`。system_server（uid 1000）
    读不到 → AOSP 的 `LOG(FATAL)` 硬断言 → SIGABRT。每次 `updateCachedAppsSnapshot`
    都会走这条路，必崩而非偶发
  - 旧代码用 `chcon` 试图修标签，但 ksu 域**没有 relabel 权限**（实测 `rc=1`），
    且 `2>/dev/null` 把失败吞了，脚本继续挂载
  - 修复：改用 **tmpfs 挂载时带 `context=u:object_r:config_gz:s0`**，
    文件继承正确的 SELinux 类型（chcon 与 `mount --bind -o context=` 均实测无效）
- **`fake_config.sh`：加四道保护，任一失败即放弃伪装**
  1. tmpfs 起不来 → 放弃，不降级成错误类型的 bind
  2. 挂载前验证暂存文件类型 == `config_gz`
  3. 挂载后再次验证，不符立刻 umount 回滚
  4. 内容自检（两项确实都改成 `y`），否则回滚
- **`service.sh`：不再无视用户的安全开关**
  - 旧版把 `fake_config.sh` 放在**最前面无条件执行**。用户写了 `no_boot`、
    在管理器里禁用模块后，`post-fs-data.sh` 正确跳过（`history.log` 有
    `BOOT SKIP (no_boot)`），但 `service.sh` 照样挂载 `/proc/config.gz` ——
    用户的"关闭"完全没生效
  - 现在开头检查 `disable` / `no_boot` / `blocked`，任一存在就不碰系统文件
- **`uninstall.sh`：补齐两层挂载的清理**
  - 原来只 `umount /proc/config.gz`，留下 `.cfgtmp` 这个 tmpfs 挂载点
  - 现在按「先解 bind 再解 tmpfs」的顺序拆，并清理旧版留下的错误类型文件

### 新增

- `scripts/check-configgzip.sh`：把上面这些规则写成 6 条断言
  （必须是 tmpfs context= / 不得依赖 chcon / 挂载前后双验证 /
  service.sh 开关顺序 / 必须检查 disable / uninstall 两层都拆）。
  **已接入 `package-ksu-zip.sh`，不通过拒绝打包**。
  用旧版文件实测能准确报出 5 项违规，新版 6 项全过。
- `docs/TROUBLESHOOTING.md` 新增「伪装文件的 SELinux 类型必须是 config_gz」
  一节，含完整崩溃栈、标签对比、四道保护说明与 `service.sh` 的教训

### 验证

- 修复版在真机上：`/proc/config.gz` 标签为 `u:object_r:config_gz:s0`、
  内容两项均为 `y`、**system_server 存活无新崩溃**
- 幂等性：重复执行不重复挂载；手动 umount 后能正确补回
- 撤回路径：`umount /proc/config.gz` + `umount .cfgtmp` 后恢复原文件

---

## v1.0.0-6.6 — 2026-11-03

首个 6.6 版本。**真机验证通过（一加 13 / OP5D0DL1 / 6.6.118）**。

### 新增

- 从 6.12 分支移植全部 6 个模块到 KMI `android15-6.6`
- `scripts/build-ddkk.sh` / `build-net-ddk.sh` 新增 `DDK_ROOT` 模式：
  解包 DDK 镜像后用 `chroot` 直接编译，不依赖 docker daemon
  （本机 `dockerd` 能 pull，但 `docker run` 卡在 `Created` 不动）
- `docs/BUILD.md` 完整记录 chroot 模式必须手工设的三组环境变量

### 修复

- **`net_macvlan/macvlan_core.c` 改用 6.6 源码**。6.12 版本在 6.6 上编不过：
  - `dev->lltx` 成员不存在（6.6 用 `NETIF_F_LLTX` 在 `ALWAYS_ON_FEATURES` 里）
  - `dev->change_proto_down` 成员不存在（6.6 用 `priv_flags |= IFF_CHANGE_PROTO_DOWN`）
  - `macvlan_ethtool_get_ts_info()` 在 6.6 是 `struct ethtool_ts_info *`，
    没有 `ethtool_get_ts_info_by_layer()`
  从 DDK 的 6.6.127 源码树取 `drivers/net/macvlan.c`，再把 shim 的
  `droid_mv_shim_resolve()` 调用挂回 `macvlan_init_module()`（diff 只有 6 处）。
- `scripts/build-ddkk.sh` 的 `DDK_ROOT` 模式补 `mkdir -p`（首次跑时
  `out/<target>` 父目录不存在会 `cp: cannot create directory`）
- `post-fs-data.sh` 的 vermagic 自检从 `vermagic=6.12` 改成 `vermagic=6.6\.`
- 机型锁从 `PMB110` 改为 SM8750 欧加真代号列表
  （`OP5D0DL1` / `PJZ110` / `OP5D0BL1` / `OP5D0AL1` / `PKZ110` / `OP5E0DL1`）
- 模块目录名从 `Droidspaces` 改为 `Droidspaces-6.6`，避免和 6.12 版本互相覆盖；
  pids 独立包 id 改为 `Droidspaces66Pids`

### 关键结论（新增）

**DDK 6.6.127 编的 ko 可以直接 insmod 进 6.6.118**，不需要自建 6.6.118 KDIR。

原因：设备 `CONFIG_MODVERSIONS=y`，模块带 `__versions` crc 段；
内核 `same_magic()` 在这种情况下**跳过首段版本号，只比较空格后的部分**：

```c
int same_magic(const char *amagic, const char *bmagic, bool has_crcs)
{
	if (has_crcs) {
		amagic += strcspn(amagic, " ");
		bmagic += strcspn(bmagic, " ");
	}
	return strcmp(amagic, bmagic) == 0;
}
```

真机验证：

```text
hello: no symbol version for module_layout
hello-probe: loaded          # rc=0，没有 vermagic 拒绝
```

⚠ 前提是 clang 版本一致：DDK 的 `clang-r510928` 与设备原厂编译内核用的是
**同一个 build**（`Android (11368308, ...) clang version 18.0.0`）。

### 真机验证结果

| 项 | 结果 |
|---|---|
| 6 个 ko 编译 | ✅ |
| 符号缺失（vs 设备 `__ksymtab_`） | 0 |
| `insmod` 6 个 | ✅ 全部 rc=0 |
| 布局自校验 | ✅ 62 项 `live == build` |
| pid namespace | ✅ `unshare -p` 子进程 `pid=1` |
| ipc namespace | ✅ `unshare -i` 成功 |
| devtmpfs | ✅ `/proc/filesystems` 出现 `nodev devtmpfs` |
| pids 显示层 | ✅ `cgroup.controllers` / `/proc/cgroups` 出现 `pids` |
| macvlan | ✅ `ip link add type macvlan` rc=0 |
| ip6tables nat | ✅ `-t nat -L` 可列 |
| user namespace | ❌ `-EINVAL`，内核未编译（预期内） |
| 卸载 `droid_lkm` | ⚠️ 容器持有 ns 时 `Try again`，需先停容器 |

### 二轮验证（同日）：容器内 Docker 真的能跑

第一轮结论「Docker 跑不了」是**错的**，特此更正。

| 现象 | 真实原因 | 处理 |
|---|---|---|
| `unsafe procfs detected: ... proc/self/setgroups` | **runc 1.3.4** 的新硬化，不是内核缺 userns | 换 runc **1.1.15** |
| `overlay: case-insensitive capable filesystem` | `/data` 是 f2fs + casefold | `storage-driver=vfs` |
| `iptables (nf_tables): Could not fetch rule set generation id` | 内核无 `CONFIG_NF_TABLES` | 切 `iptables-legacy` |

三条都满足后 `docker run --rm --runtime=runc115 hello-world` 输出
`Hello from Docker!`，实测通过。

**误判复盘**：我先用手写的最小 OCI spec 测 `runc run`，缺标准挂载导致
`/dev/null permission denied`，据此认为「runc 在这个内核上跑不了任何容器」。
实际标准 `runc spec` 自带 `/proc` `/dev` `/dev/pts` `/dev/shm` `/sys`
五个挂载，补上就能过 —— 手工最小 spec 不能当判据。

### 新增

- `src/dsm/tools/setup-docker.sh`：容器内一键配置（runc 1.1.15 + iptables legacy
  + daemon.json + 起 dockerd + 冒烟测试），支持 `check` 子命令
- `docs/tutorials/04-docker.md` 全部重写：三个必要条件、DNS 的 IPv6 坑、
  错误对照表、vfs 代价
- WebUI「容器独立 uid」开关改为**由模块判定驱动**：
  读 `/proc/droid_lkm_misc/status` 的 `userns` 行，
  `ready` → 启用；`unsupported` / `off` → 禁用并显示原因；
  新增「模块检查」徽章与状态行。`paintUState()` 不再自行改开关
  （避免和 `doStatus()` 互相覆盖），`change` 事件再加一道守卫。

### 修复：WebUI 一直显示「检测中」

改 userns 开关逻辑时引入两个 bug，页面完全无响应（状态徽章停在初始占位文字）：

| # | 错误 | 影响 |
|---|---|---|
| 1 | 拆 `_writeUsernsIntent()` 时把结尾 `}` 误写成 `});` | 整个 `<script>` 语法错误，一行都不执行 |
| 2 | 重写 HTML 时删掉 `<b id="uBase">`／`uBase2`，JS 仍对其赋值 | `doStatus()` 抛 TypeError 中断，后面的徽章全部停住 |

第 2 个更隐蔽：`doStatus` 是整页渲染入口，任何空引用都会让**后面所有状态**停在初始化值，
而 `.catch` 只把 pill 改成「读取失败」，看起来像加载失败而不是代码 bug。

**防复发**：新增 `scripts/check-webui.sh`

- 抽出 `<script>` 块交给 `node --check`
- 交叉核对 `getElementById("x")` 的每个 id 是否存在于 HTML
- 没有 node 时退化为括号平衡检查
- **`package-ksu-zip.sh` 已强制调用**，检查不过拒绝打包

并补了 `docs/TROUBLESHOOTING.md` 的对应小节（含两种错误的分辨方法）。

### 已知限制

- 容器 root = 宿主 root（无 `CONFIG_USER_NS`）
- `--pids-limit` 建议 ≥ 256（空跑容器自身约 68 进程）
- 无 `NF_TABLES` / `IP_SET` / `BRIDGE_NETFILTER`（内核未编译）
- 只在 OP5D0DL1 / 6.6.118 一台机器上验证过

---

## 附：6.12 分支的结论（不是本分支的历史，仅供参考）

这些是从 `droidspaces-6.12-pmb110` 继承下来的、在本分支同样成立的结论：

- **`CONFIG_USER_NS` 补不了**。LKM 只能在 syscall 边界做 id 翻译，拿不到真命名空间。
  `/proc/sys/user/max_user_namespaces` 有值**不**代表支持 userns。
- **KCFI 必须匹配**。clang 版本不对，`insmod` 不是报错而是 `CFI failure` + 整机断电。
- **pids 控制器是模拟的**：显示层 hook 打印函数，功能层用
  `cgroup_add_dfl_cftypes()` 往 memory 子系统挂 `pids.max`，再用 kprobe
  在 `cgroup_can_fork()` 返回 `-EAGAIN`。
- 6.12 分支 v1.0.18 的 `kernel_clone` 钩子（fork 热路径换 cred）会导致整机重启，
  本分支已不含该路径。
