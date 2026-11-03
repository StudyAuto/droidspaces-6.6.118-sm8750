#!/system/bin/sh
# 让容器里的 Docker 能真正跑起来（在 Droidspaces 容器内执行，不是宿主）
#
# 用法（容器内 root）：
#   sh /opt/setup-docker.sh            # 配置 + 启动 dockerd + 跑 hello-world
#   sh /opt/setup-docker.sh check      # 只做前置检查
#
# 为什么需要这个脚本：本机内核有三个限制，Docker 的默认值全都踩中
#   1) 无 CONFIG_USER_NS → runc 1.3.x 报 "unsafe procfs detected" 直接拒绝
#      → 必须换成 runc 1.1.15
#   2) /data 是 f2fs + casefold → overlayfs 被内核拒绝
#      → 必须 storage-driver=vfs
#   3) 无 CONFIG_NF_TABLES → iptables nft 后端不可用
#      → 必须切 iptables-legacy
#
# 三个条件缺一不可，失败信息都不指向真正原因，所以写成一个脚本。

set -e

RUNC=/usr/local/bin/runc-1.1.15
RUNC_VER=1.1.15
RUNC_URL="https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.arm64"
DAEMON_JSON=/etc/docker/daemon.json

say() { echo "[docker-setup] $*"; }
die() { echo "[docker-setup] 错误: $*" >&2; exit 1; }

check_only=0
[ "$1" = "check" ] && check_only=1

# ---------- 架构守卫：runc 必须下 arm64 的 ----------
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || die "本脚本只针对 aarch64（当前 $ARCH）"

if [ "$check_only" = 1 ]; then
	say "架构: $ARCH"
	say "CONFIG_USER_NS: $(zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_USER_NS=y' >/dev/null && echo y || echo n)  (n → 必须用 runc 1.1.x)"
	say "overlay on /data:  $(mount -t overlay overlay -o lowerdir=/tmp,upperdir=/tmp,workdir=/tmp /mnt 2>/dev/null && { umount /mnt; echo ok; } || echo unavailable)"
	say "iptables 后端:     $(iptables --version 2>/dev/null || echo '未安装')"
	say "runc 1.1.15:       $([ -x $RUNC ] && $RUNC --version | head -1 || echo '未安装')"
	exit 0
fi

# ---------- 1) runc 1.1.15 ----------
if [ ! -x "$RUNC" ]; then
	say "下载 runc $RUNC_VER ..."
	mkdir -p /usr/local/bin
	if command -v curl >/dev/null 2>&1; then
		curl -fL -o "$RUNC" "$RUNC_URL" || die "下载失败（容器内能上网吗？）"
	else
		die "需要 curl：apt-get install -y curl"
	fi
	chmod +x "$RUNC"
fi
$RUNC --version | head -1 | grep -q "$RUNC_VER" || die "$RUNC 版本不是 $RUNC_VER"
say "runc: $($RUNC --version | head -1)"

# ---------- 2) iptables legacy ----------
if iptables --version 2>/dev/null | grep -q nf_tables; then
	say "iptables 切到 legacy 后端"
	update-alternatives --set iptables  /usr/sbin/iptables-legacy  >/dev/null 2>&1 || true
	update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
	# arptables / ebtables 的 legacy 变体在 Ubuntu 24.04 没注册，报错忽略
fi
iptables -t nat -N DOCKER 2>/dev/null && iptables -t nat -X DOCKER 2>/dev/null
say "iptables: $(iptables --version 2>/dev/null || echo 未安装)"

# ---------- 3) daemon.json ----------
mkdir -p /etc/docker
cat >"$DAEMON_JSON" <<'EOF'
{
  "storage-driver": "vfs",
  "runtimes": {
    "runc115": { "path": "/usr/local/bin/runc-1.1.15" }
  }
}
EOF
say "写入 $DAEMON_JSON（vfs + runc115）"

# ---------- 4) DNS：容器内 resolv.conf 是 bind mount，只能在这里改 ----------
if ! getent ahostsv4 registry-1.docker.io >/dev/null 2>&1; then
	say "IPv4 解析失败，覆写 /etc/resolv.conf"
	printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' >/etc/resolv.conf 2>/dev/null || \
		say "  警告: 改不了 /etc/resolv.conf（只读？），镜像拉取可能失败"
fi

# ---------- 5) 启动 ----------
pkill dockerd 2>/dev/null || true
sleep 2
say "启动 dockerd ..."
nohup dockerd >/tmp/dockerd.log 2>&1 &

i=0
while [ $i -lt 30 ]; do
	docker info >/dev/null 2>&1 && break
	i=$((i + 1))
	sleep 1
done
docker info >/dev/null 2>&1 || { tail -20 /tmp/dockerd.log; die "dockerd 起不来"; }

say "dockerd 就绪:"
docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Cgroup Version"

# ---------- 6) 冒烟测试 ----------
say "跑 hello-world（需要 --runtime=runc115）..."
if docker run --rm --runtime=runc115 hello-world 2>&1 | grep -q "Hello from Docker"; then
	say "✅ Docker 可用"
else
	say "❌ hello-world 失败，日志："
	tail -20 /tmp/dockerd.log
	exit 1
fi

exit 0
