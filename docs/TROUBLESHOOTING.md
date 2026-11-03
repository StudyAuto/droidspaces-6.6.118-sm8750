# 故障排查

按"症状 → 判断 → 处理"组织。**先看症状表定位，再看对应小节。**

---

## 症状速查

| 症状 | 跳到 |
|---|---|
| 手机直接重启 / 关机 | [① 整机重启](#一整机重启--关机) |
| 容器里 `su: cannot set groups` | [② su cannot set groups](#二su-cannot-set-groups) |
| 容器起不来，`already in use` | [③ 容器起不来](#三容器起不来) |
| `relabel` 卡住不动 / 秒出几十个 ok 但没改 | [④ relabel 无效](#四relabel-卡住或假成功) |
| App 里「允许沙箱」「硬件访问」显示不可用 | [⑤ App 显示不可用](#五app-显示允许沙箱不可用) |
| 卸模块时 panic / 关机 | [⑥ 卸载崩溃](#六卸载模块时崩溃) |
| 每次开机容器白失败一次 | [⑦ 开机自启冲突](#七每次开机容器白失败一次) |
| 状态页显示自相矛盾 | [⑧ 状态页打架](#八状态页自相矛盾) |
| 想知道到底有没有 userns | [⑨ 判定 userns](#九如何正确判定-userns) |

---

## ① 整机重启 / 关机

**特征**：`dmesg` 里什么都没有（内存日志随重启清空），`pstore` 里只有联发科
`CLKCHK` / `mrdump`  dump，**没有 oops 栈**。

这说明不是普通野指针崩溃，而是引用计数或指针被打穿后直接 hang，硬件看门狗接管。

**已知原因（已修复，仅 v1.0.16 ~ v1.0.18 有）**：
`kernel_clone` 钩子在每次 fork 时把 cred 的 `user_ns` 换成模块伪造的结构，
`cap_capable()` 遍历 `cred->user_ns->parent` 时读到野指针。

**处理**：

```sh
# 1. 确认 adopt 开关是关的
su -c 'cat /sys/module/droid_lkm_misc/parameters/userns_adopt'

# 2. 如果是 Y，删掉开关文件并重载
su -c 'find /data/adb/modules -name userns_adopt -delete
       echo 1 > /sys/module/droid_lkm_misc/parameters/release
       rmmod droid_lkm_misc
       insmod /data/adb/modules/Droidspaces-6.6/ko/droid_lkm_misc.ko real_userns=1 userns_any=1'

# 3. 抓上次崩溃现场（pstore 写在 flash 上，重启不清）
su -c 'ls -l /sys/fs/pstore/; tail -n 250 /sys/fs/pstore/console-ramoops-0'
```

**升级到 v1.0.0+ 后不会再出现**（整条路径已删除）。

---

## ② `su: cannot set groups`

**特征**：容器能进、`ls` / `cat` / `apt` 都正常，只有 `su` 报错。

**原因**：`/usr/bin/su` 是 setuid 程序（`-rwsr-xr-x`）。执行时 euid 变成**文件属主**。
如果 rootfs 里文件属主是 `200000` 而容器进程是 `0`，`su` 一执行 euid 就成了 200000，
而 200000 没有 `CAP_SETGID` → 报错。

**判断（一条命令）**：

```sh
su -c 'ls -ln /data/local/Droidspaces/Containers/root/rootfs | head -3'
```

- 属主 `200000 200000` → **A 类**，磁盘没恢复
- 属主 `0 0` → **B 类**，进程凭据被改了（v1.0.18 及更早的问题，v1.0.0 已修复）

**A 类处理**（约 130 秒）：

```sh
su -c 'droidspaces --config=/data/local/Droidspaces/Containers/root/container.config stop
       sh /data/adb/modules/Droidspaces-6.6/userns.sh restore all'
```

**B 类处理**：升级到 v1.0.0 或更高。

**根本原则**：

> **磁盘属主必须和容器进程 uid 对齐。**
> 容器进程是 0 → 磁盘就该是 0；容器进程是 200000 → 磁盘才该是 200000。
> 本机没有 userns，容器进程**永远是 0**，所以**磁盘永远是 0，不要 relabel。**

---

## ③ 容器起不来

### `already in use by PID xxxx`

容器其实在跑。要么进它，要么先停：

```sh
su -c 'droidspaces --config=/data/local/Droidspaces/Containers/root/container.config stop'
```

### `inaccessible or not found`

`droidspaces` 不在 `PATH`。用全路径：

```sh
su -c '/data/local/Droidspaces/bin/droidspaces --config=... start'
```

### 缺模块

容器需要 `droid_lkm`（PID/IPC ns）。检查：

```sh
su -c 'grep "^droid_lkm" /proc/modules'
```

缺就补：

```sh
su -c 'PH_ACTION=1 sh /data/adb/modules/Droidspaces-6.6/post-fs-data.sh'
```

---

## ④ `relabel` 卡住或假成功

**已在本仓库的 `userns.sh` 中修复。** 记录原因，供改脚本时避坑。

### 坑 1：toybox `find` 不支持 `-exec ... {} +`

```sh
find . -uid 0 -exec chown 200000 {} +     # ❌ Android 上静默无效
```

改成 `-print0 | xargs -0`。

### 坑 2：toybox `find` 不支持 `-uid` / `-gid`

```sh
$ find . -uid 0
find: bad arg '0'
```

### 坑 3（最阴）：`xargs -r` 空输入返回 0

组合坑 2 之后，`find` 一条文件都没输出，`xargs -r` 收到空输入**返回 0**，
脚本打印 36 个 `ok`，实际一个文件都没改。

### 正确写法（stat 建表法）

```sh
# 一次遍历，建立 "uid 路径" 表
find "$ROOT" -print0 | xargs -0 stat -c '%u %n' > /tmp/ids

# 取出实际存在的 uid
ids=$(cut -d' ' -f1 /tmp/ids | sort -un)

for id in $ids; do
    [ "$id" -ge "$BASE" ] && continue
    sed -n "s/^$id //p" /tmp/ids | tr '\n' '\0' | xargs -0 chown -h "$((id+BASE))"
done
```

要点：
- `chown -h` 处理符号链接本身
- gid 用 `chgrp` 而不是 `chown :gid`（避免歧义）
- 进度写 **stderr**，别污染 stdout
- `check` 的判据是「uid < base 的数量」，不是「找出多少个 id」

真机性能：52.3 万文件，relabel 174 秒，restore 132 秒。

### 护栏

v1.0.0 的 `userns.sh relabel` 会先检查有没有进程真在 userns 里：

```sh
# 只要所有 uid_map 都是恒等映射（0 0 4294967295），直接拒绝
```

强制执行需要 `--force`。**在本机上不要加 `--force`。**

---

## ⑤ App 显示「允许沙箱」不可用

**原因**：Droidspaces App 判断 userns 支持的方式是**读 `/proc/config.gz`**，
看到 `# CONFIG_USER_NS is not set` 就直接放弃，连 syscall 都不试。

**处理**（`fake_config.sh`，模块已自带）：

把 `config.gz` 解开、改两行、重压缩，覆盖 `/proc/config.gz`。

```sh
su -c 'sh /data/adb/modules/Droidspaces-6.6/tools/fake_config.sh'
su -c 'zcat /proc/config.gz | grep -E "CONFIG_USER_NS|CONFIG_DEVTMPFS"'
# 期望：CONFIG_USER_NS=y / CONFIG_DEVTMPFS=y
```

**但必须清楚**：这只是让 App 的**探测**过关，不提供任何真实能力。
这个脚本骗过 App 的同时也骗过开发者，本项目为此绕了三天。

要撤回：

```sh
su -c 'umount /proc/config.gz'
su -c 'umount /data/adb/modules/Droidspaces-6.6/.cfgtmp'
```

### ⚠️ 伪装文件的 SELinux 类型必须是 `config_gz`（2026-11-03 血泪教训）

**这一节是真实线上故障的记录，改 `fake_config.sh` 前必须读完。**

**症状**：手机开机后 system_server 反复崩溃、整机重启，应用全部被杀。
dropbox 里有 `system_server_native_crash`，abort message 是：

```text
Check failed: result == OK Kernel configs could not be fetched. b/151092221
  #04 android_os_Debug_isVmapStack
  #07 MemInfoReader.getKernelUsedSizeKb
  #08 AppProfiler$CachedAppsWatermarkData.updateCachedAppsSnapshot
```

**原因**：旧版把 `/data/adb/.../etc/config.gz` 直接 bind 到 `/proc/config.gz`。
那个文件的 SELinux 类型是 **`adb_data_file`**，而真文件是 **`config_gz`**：

```text
真文件    /proc/config.gz          u:object_r:config_gz:s0      ← system_server 可读
错类型    (bind 自 /data/adb)      u:object_r:adb_data_file:s0  ← system_server 读不到
```

`system_server`（uid 1000）读不到 → `Debug.isVmapStack()` 的 `ReadFileToString`
失败 → AOSP 里是 `LOG(FATAL)` 硬断言 → **SIGABRT → 整机重启**。
它每次 `updateCachedAppsSnapshot` 都会走这条路径，**不是偶发，是必崩**。

旧代码试图用 `chcon "$CTX" "$DST" 2>/dev/null` 修标签，但：

- ksu 域**没有 relabel 权限**，`chcon` 到 `config_gz` 直接被拒（实测 `rc=1`）；
- `2>/dev/null` 把失败**吞掉了**，脚本继续往下挂载 —— 埋雷。

**正确做法**（现在的实现）：用 **tmpfs 挂载时的 `context=`** 设类型，文件继承挂载点上下文：

```sh
mount -t tmpfs -o "size=512k,mode=755,context=u:object_r:config_gz:s0" tmpfs "$STAGE"
```

实测这样建出来的文件标签就是 `config_gz`，bind 到 `/proc/config.gz` 后
`system_server` 能正常读取（修复后 system_server 存活、无新崩溃）。

脚本现在有四道保护，任何一道不过就**放弃伪装**（App 显示 userns 不可用），
绝不把错类型的文件盖上去：

1. tmpfs 起不来 → 放弃（不退化成错误类型的 bind）
2. 挂载前验证暂存文件类型 == `config_gz`
3. 挂载后再次验证 `/proc/config.gz` 类型 == `config_gz`，不符立刻 umount
4. 内容自检：两项确实都变成了 `y`，否则回滚

**另一个必须记住的坑：`service.sh` 曾经无视 `no_boot`。**

用户写了 `no_boot`、在管理器里禁用了模块，`post-fs-data.sh` 正确跳过
（`history.log` 有 `BOOT SKIP (no_boot)`），但 `service.sh` 把
`fake_config.sh` 放在**最前面无条件执行** —— 用户的"关闭"完全没生效，
照样挂载、照样崩。

现在 `service.sh` 会在开头检查 `disable` / `no_boot` / `blocked`，任一存在就不碰系统文件。
**规则：任何会改动系统状态的动作，都必须先过这三道开关。**

校验脚本 `scripts/check-configgzip.sh` 把以上规则都写成了断言，已接入打包流程。

---

## ⑥ 卸载模块时崩溃

**特征**：`vfs_open → try_module_get → do_page_fault`，Comm 是 `head` 或 `cat` 之类。

**原因**：容器还在跑，模块的 ns 对象 / `file_system_type` 仍被引用，`rmmod` 后变野指针。

**现在的保护**（v1.0.15+）：

- `droid_lkm_userns_busy()` 非 0 → `release` 返回 `-EBUSY`
- devtmpfs `s_active > 1` → 拒绝卸载

所以 `rmmod` 大概率直接失败而不是崩。但**不是零风险**，正确姿势永远是：

```sh
# 先停容器，再卸模块
su -c 'droidspaces --config=/data/local/Droidspaces/Containers/root/container.config stop
       echo 1 > /sys/module/droid_lkm_misc/parameters/release
       rmmod droid_lkm_misc'
```

---

## ⑦ 每次开机容器白失败一次

**原因**：两边不一致

| 位置 | 字段 | 含义 |
|---|---|---|
| 模块 | `no_boot` 文件存在 | 开机**不**加载模块 |
| 容器 | `run_at_boot=1` | 开机**要**启容器 |

于是开机时 droidspacesd 去拉容器 → 模块还没加载 → 失败。

**处理**（二选一）：

**A. 让模块也自启**（稳定后推荐）
WebUI → 打开「开机自动加载」，延迟 30 秒，bootloop 守卫也打开。

**B. 让容器别自启**

```sh
su -c 'C=/data/local/Droidspaces/Containers/root/container.config
       sed -i "s/^run_at_boot=.*/run_at_boot=0/" "$C"
       grep ^run_at_boot "$C"'
```

> ⚠️ 改完别在 App 里点「保存配置」——App 会用它界面上的缓存状态覆盖回去。

---

## ⑧ 状态页自相矛盾

**v1.0.0 及更早的特征**：

```
容器 uid_map:  未映射          ← 真话
真 userns:     已生效 · 18/18  ← 假的
```

原因：`real=1` 只表示 18 个 id 翻译钩子**挂上了**，跟容器有没有命名空间无关。
钩子挂满也造不出 userns。

**v1.0.0 已修**：按容器进程的真实 `uid_map` 判定，恒等映射就显示"未生效"。

判断真假的通用方法：**不要看模块自报，看容器进程本身**。

```sh
su -c 'P=$(grep -lF "Containers/root/rootfs" /proc/[0-9]*/mountinfo 2>/dev/null | head -1 | cut -d/ -f3)
       echo "P=$P"; cat /proc/$P/uid_map; ls -l /proc/$P/ns/'
```

---

## ⑨ 如何正确判定 userns

**唯一正确的方法**（两秒钟）：

```sh
su -c 'echo 1 > /sys/module/droid_lkm_misc/parameters/release
       rmmod droid_lkm_misc
       unshare -U true; echo "rc=$?"
       insmod /data/adb/modules/Droidspaces-6.6/ko/droid_lkm_misc.ko real_userns=1 userns_any=1'
```

| 结果 | 含义 |
|---|---|
| `Invalid argument` / rc=1 | **EINVAL** → 内核没编译 `CONFIG_USER_NS`，userns 不可用 |
| `Operation not permitted` | EPERM → 有 userns，被策略挡（SELinux / seccomp / sysctl） |
| 成功 rc=0 | 内核原生支持 |

**不要用这些判断**：

| ❌ 不可靠 | 为什么 |
|---|---|
| `/proc/sys/user/max_user_namespaces` 有值 | 厂商内核残留节点，值是 `pid_max` 派生的 |
| `/proc/config.gz` 里的 `CONFIG_USER_NS` | 可能被 `fake_config.sh` 改过 |
| WebUI 显示「18/18 真映射」 | 只表示钩子挂了 |
| `dmesg` 有 `userns hooks installed` | 只表示模块加载成功 |
| `unshare -U` 返回 0 | 模块可能"假成功"（剥掉了 flag） |

**只有「模块不在时调 syscall 看 errno」是真的。**

---

## 附：常用诊断命令

```sh
# 一键看全部状态
su -c 'echo "模块: $(grep -c "^droid_lkm" /proc/modules)/4"
       echo "版本: $(grep -m1 ^version= /data/adb/modules/Droidspaces-6.6/module.prop)"
       echo "页面: $(md5sum /data/adb/modules/Droidspaces-6.6/webroot/index.html | cut -d" " -f1)"
       echo "自启: $([ -f /data/adb/modules/Droidspaces-6.6/no_boot ] && echo 关 || echo 开)"
       echo "容器自启: $(grep ^run_at_boot= /data/local/Droidspaces/Containers/root/container.config)"
       echo "存储直通: $(grep ^enable_android_storage= /data/local/Droidspaces/Containers/root/container.config)"'

# 找容器 pid
su -c 'P=$(grep -lF "Containers/root/rootfs" /proc/[0-9]*/mountinfo 2>/dev/null | head -1 | cut -d/ -f3); echo $P'

# 看容器的 ns
su -c 'P=...; ls -l /proc/$P/ns/'

# 看容器的 capability
su -c 'P=...; grep -E "^Cap(Eff|Bnd|Prm)" /proc/$P/status'

# 看容器的挂载
su -c 'P=...; cut -d" " -f5 /proc/$P/mountinfo'

# 抓上次崩溃现场
su -c 'tail -n 250 /sys/fs/pstore/console-ramoops-0'
```

---

## WebUI 一直显示「检测中」/「读取中…」

**现象**：打开模块 WebUI，「模块状态」徽章永远停在初始文字「检测中」，
其它卡片也不更新。没有任何错误弹窗。

**根因**：`index.html` 里的 JS 有语法错误或运行期异常。
整段 `<script>` 不会执行，DOM 就停在 HTML 里写死的占位文字上。

本仓库实测遇到过两次（2026-11-03），都是改 userns 开关逻辑时引入的：

| # | 错误 | 表现 |
|---|---|---|
| 1 | 拆函数时把结尾 `}` 误写成 `});` | 整个 script 块语法错误，**什么都不执行** |
| 2 | 删掉了 `<b id="uBase">` 但 JS 仍在 `getElementById("uBase").textContent = ...` | 语法没问题，但 `doStatus()` 执行到一半抛 TypeError，`.catch` 把 pill 设成「读取失败」或停在「检测中」 |

第 2 种更隐蔽：`doStatus` 是整页状态渲染的入口，中间任何一个空引用
都会让后面所有徽章停在初始化值。

**自查**

```sh
cd src
sh scripts/check-webui.sh
```

```
webui 语法 OK (1087 行 JS)
webui DOM 引用 OK（72 个 id 全部存在）
```

这个脚本做两件事：

1. 抽出所有 `<script>` 块交给 `node --check` 做完整语法检查
2. 用 python 交叉核对 `document.getElementById("x")` 里每个 id
   是否真的存在于 HTML

**`package-ksu-zip.sh` 已经内置调用它**，检查不过会拒绝打包 ——
因为这类错误刷到手机上只能靠肉眼发现，且现象完全没有指向性。

**手工定位运行期错误**

浏览器里打开 WebUI 后连电脑看控制台最直接。没有条件时，
可以把 `doStatus` 的 catch 临时改成 `console.log(err.stack)`，
再在页面里触发一次刷新。

**修复要点**

- 任何 `document.getElementById(...)` 的返回值在**删除 HTML 元素后**
  都必须判空（这次 `uBase`/`uBase2` 就是这个原因）
- 拆函数时检查收尾符：`function f(){...}` 结尾是 `}`，不是 `});`
