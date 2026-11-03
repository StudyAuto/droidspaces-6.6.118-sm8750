# ④ 在容器里跑 Docker

目标：容器内 `dockerd` 起来、**能真正 `docker run`**、能拉镜像。

> 本页所有步骤都在真机（OP5D0DL1 / 6.6.118）验证过，2026-11-03。

---

## 1. 先看结论：三个必要条件

这台机器上能让 Docker 跑起来，必须同时满足三条。**缺任何一条都会失败**，
而且失败信息都不指向真正的原因。

| # | 条件 | 不满足时的报错 |
|---|---|---|
| 1 | **runc 用 1.1.15**（不能用 Ubuntu 24.04 自带的 1.3.4） | `unsafe procfs detected: ... proc/self/setgroups: no such file or directory` |
| 2 | **storage-driver = vfs**（不能用 overlay2） | `overlay: case-insensitive capable filesystem on ... not supported` |
| 3 | **iptables 用 legacy 后端**（不能用 nft） | `failed to create NAT chain DOCKER: iptables v1.8.10 (nf_tables): Could not fetch rule set generation id: Invalid argument` |

原因分别对应：

1. 内核没有 `CONFIG_USER_NS` → `/proc/self/setgroups` 不存在。
   runc 1.3.x 把「procfs 缺 setgroups」当 fatal 直接拒绝；**1.1.15 不会**。
   这是 runc 新加的安全检查，不是内核能力缺失。
2. `/data` 是 f2fs 且带 **casefold**，Android GKI 的 overlayfs 会拒绝
   `sb_has_encoding()` 的底层文件系统（`fs/overlayfs/params.c`）。
   修它要打内核补丁 `Kernel_6.6.patch`，**要刷内核**，本项目不刷。
3. 内核没编 `CONFIG_NF_TABLES`，而 Ubuntu 24.04 的 iptables 默认走 nft 后端。

---

## 2. 前置检查

```sh
su -c 'grep -E "^(droid_lkm|droid_lkm_pids) " /proc/modules'
```

两个都在再继续。容器本身要能起，见 [② 第一个容器](02-container.md)。

---

## 3. 装 Docker

容器内执行（`droidspaces --name=<名> run '...'` 或 `enter` 进去）：

```sh
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io
```

装完会有 `invoke-rc.d: unknown initscript` 的提示，**正常** —— 容器里没有
systemd 的 init 脚本，Docker 要手动起。

---

## 4. 三处必须改的地方

### 4.1 换掉 runc（**最关键**）

Ubuntu 24.04 自带 runc 1.3.4，必须换成 1.1.15：

```sh
# 在宿主上（或容器内能联网时直接 curl）
curl -L -o /usr/local/bin/runc-1.1.15 \
  https://github.com/opencontainers/runc/releases/download/v1.1.15/runc.arm64
chmod +x /usr/local/bin/runc-1.1.15
runc-1.1.15 --version     # runc version 1.1.15
```

> ⚠ 一定要下 **`runc.arm64`**，不是 `runc.amd64`。
> 拿错架构会报 `exec format error`。

### 4.2 iptables 切 legacy

```sh
update-alternatives --set iptables  /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

验证：

```sh
iptables -t nat -N DOCKER && echo OK
```

`arptables` / `ebtables` 的 legacy 变体在 Ubuntu 24.04 里没注册，
`update-alternatives` 会报错，**忽略即可**，不影响 Docker。

### 4.3 daemon.json

`/etc/docker/daemon.json`：

```json
{
  "storage-driver": "vfs",
  "runtimes": {
    "runc115": { "path": "/usr/local/bin/runc-1.1.15" }
  }
}
```

> 不要把 `storage-driver` 同时写在命令行和文件里，dockerd 会报
> `the following directives are specified both as a flag and in the configuration file`。

---

## 5. 起 dockerd 并验证

```sh
nohup dockerd >/tmp/dockerd.log 2>&1 &
sleep 15

docker info | grep -E "Server Version|Storage Driver|Cgroup"
```

应该看到：

```
 Server Version: 29.1.3
 Storage Driver: vfs
 Cgroup Version: 2
```

**关键一步** —— 必须带 `--runtime=runc115`：

```sh
docker run --rm --runtime=runc115 hello-world
```

预期：

```
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

跑通了。

> 也可以把 `"default-runtime": "runc115"` 写进 daemon.json，这样不用每次带参数。
> 但**不建议**改 `dockerd` 的默认 runtime 之外的东西 —— 出问题时更难排查。

---

## 6. DNS：容器里解析不出 IPv4

Droidspaces 启动时会用自己的一组 DNS 覆盖容器的 `/etc/resolv.conf`
（`1.1.1.1` / `8.8.8.8` / `2606:4700:4700::1111`）。

本机实测的问题：`registry-1.docker.io` 会先返回 **IPv6**，
而容器没有 IPv6 路由（`disable_ipv6` / 宿主没有 v6 出口），于是：

```
dial tcp: lookup registry-1.docker.io on [2606:4700:4700::1111]:53: i/o timeout
```

解决：在**容器内**覆写 `/etc/resolv.conf`（宿主上改不了，它是 bind mount）：

```sh
# 容器内
printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf
```

同样的原因，`apt` 源也要用**没有 AAAA 记录**的：

```sh
cat > /etc/apt/sources.list <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports noble main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe multiverse
EOF
```

`mirrors.tuna.tsinghua.edu.cn` / `mirrors.ustc.edu.cn` 在本机会解析成
IPv6 而连不通；`ports.ubuntu.com` 可以。

---

## 6.5 一键脚本

`setup-docker.sh` 在模块包里（`tools/setup-docker.sh`），但**容器内看不到
`/data/adb`**（pid/mnt 隔离），所以要先拷进容器 rootfs：

```sh
# 宿主上（su）
cp /data/adb/modules/Droidspaces-6.6/tools/setup-docker.sh \
   /data/local/Droidspaces/Containers/<容器名>/rootfs/opt/
chmod +x /data/local/Droidspaces/Containers/<容器名>/rootfs/opt/setup-docker.sh
```

然后容器内执行：

```sh
sh /opt/setup-docker.sh check   # 只检查环境
sh /opt/setup-docker.sh         # 全套：runc + iptables + daemon.json + 起 dockerd + 冒烟测试
```

脚本做的事就是 §4 那三处修改 + 启动 + `hello-world` 验证。
`check` 子命令的输出可以直接贴进 issue：

```text
[docker-setup] 架构: aarch64
[docker-setup] CONFIG_USER_NS: n  (n → 必须用 runc 1.1.x)
[docker-setup] overlay on /data:  unavailable
[docker-setup] iptables 后端:     iptables v1.8.10 (legacy)
[docker-setup] runc 1.1.15:       runc version 1.1.15
```

> `CONFIG_USER_NS: n` 是脚本读容器内 `/proc/config.gz` 得到的，**这是真实值**。
> 宿主上的 `/proc/config.gz` 被 `tools/fake_config.sh` bind mount 伪装成了 `y`
> （为了骗过 Droidspaces App 的能力探测），但容器有自己的 `/proc`，
> 读到的是内核真实配置：
>
> ```sh
> # 宿主（伪装后）
> $ zcat /proc/config.gz | grep USER_NS
> CONFIG_USER_NS=y
> # 容器内（真实）
> $ zcat /proc/config.gz | grep USER_NS
> # CONFIG_USER_NS is not set
> ```
>
> 所以容器里跑的判断是准的；宿主侧那份 y 不能信。

---

## 7. vfs 的代价

`vfs` 不做分层复用，每层完整复制一份：

| 项 | overlay2 | vfs |
|---|---|---|
| 磁盘占用 | 共享层 | 每层 ×N |
| 拉镜像速度 | 快 | 慢 |
| 建容器 | 快 | 慢 |

所以不要在这上面堆很多镜像。定期清：

```sh
docker system df
docker system prune -af
```

---

## 8. 端口映射

容器内 `docker run -p 8080:80` 的话，因为 Droidspaces 容器是 **NAT** 模式
（`NAT IP: 172.28.x.x`），要访问需要在**手机**上访问那个 NAT IP，
或者用 Droidspaces 的 `-B` / 端口转发配置。

最简单的验证方式是在容器内直接访问：

```sh
docker run -d --name web -p 8080:80 nginx:alpine
curl -I 127.0.0.1:8080     # 在容器内执行
```

---

## 9. 常见错误对照

| 报错 | 原因 | 处理 |
|---|---|---|
| `unsafe procfs detected: ... setgroups` | 用了 runc 1.3.x | 换 1.1.15，加 `--runtime=runc115` |
| `overlay: case-insensitive capable filesystem ... not supported` | f2fs casefold | 用 `vfs` |
| `iptables v1.8.10 (nf_tables): Could not fetch rule set generation id` | nft 后端 | 切 `iptables-legacy` |
| `directives are specified both as a flag and in the configuration file` | 命令行和文件重复 | 只留一处 |
| `exec format error` | 下错 runc 架构 | 用 `runc.arm64` |
| `lookup registry-1.docker.io ... i/o timeout` | DNS 走 IPv6 | 容器内改 `resolv.conf` |
| `Cannot connect to the Docker daemon` | dockerd 没起 | `tail /tmp/dockerd.log` |

---

## 10. 这些限制的根源

| 现象 | 根因 | 能不能改 |
|---|---|---|
| 必须用旧版 runc | 内核无 `CONFIG_USER_NS` | ✅ 换 runc 即可，已解决 |
| 不能用 overlay2 | `/data` f2fs casefold | ❌ 要刷内核 |
| 不能用 nft | 内核无 `CONFIG_NF_TABLES` | ❌ 要刷内核 |
| 容器无独立 uid | 内核无 `CONFIG_USER_NS` | ❌ 要刷内核 |

前两条不刷内核就能绕过；后两条绕不过去。
「没有隔离」正是 `CONFIG_USER_NS` 缺失的后果，见 [原理](../PRINCIPLE.md)。
