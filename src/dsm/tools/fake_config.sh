#!/system/bin/sh
# /proc/config.gz 伪装
#
# Droidspaces App 判断「允许沙箱 / 硬件访问」是否可用，读的是内核配置里的
#   CONFIG_USER_NS
#   CONFIG_DEVTMPFS
# 本机内核两项都是 "not set"，所以它直接判死，连 unshare 都不调用
# （dmesg 里一条 unshare/clone 记录都没有），并且把 allow_sandboxing 写回 0。
#
# 模块在运行时能补的只有 devtmpfs（注册一个同名文件系统，让 /proc/filesystems
# 里出现它）。userns 补不了 —— 内核没编译 CONFIG_USER_NS，模块只能在 syscall
# 边界做 id 翻译，拿不到真正的命名空间。
#
# 这里把两行都改成 y，纯粹是让 App 的探测过关、不再把 allow_sandboxing 写回 0。
# 它伪装的是「能力声明」，不是「容器真的进了 user namespace」：
# App 读到的 CONFIG_USER_NS=y 是假的，容器进程的 uid_map 仍然是
# 0 0 4294967295。这一点在 README.txt「真 userns —— 本机做不到」里有说明。
#
# 原文件仍在内核里，umount /proc/config.gz 立刻恢复；卸载模块时 uninstall.sh
# 也会做这件事。
#
# ═══════════════════════════════════════════════════════════════════════
# ⚠️ 安全约束（2026-11-03 线上故障后加，改动前务必读完）
#
# 旧实现直接把 /data/adb 下的文件 bind 到 /proc/config.gz。那个文件的
# SELinux 类型是 adb_data_file（chcon 成 config_gz 会被策略拒绝，且旧代码
# 用 2>/dev/null 把失败吞了），于是：
#
#     system_server (uid 1000) 读 /proc/config.gz → Permission denied
#       → MemInfoReader.getKernelUsedSizeKb → Debug.isVmapStack()
#       → LOG(FATAL) "Kernel configs could not be fetched. b/151092221"
#       → SIGABRT，system_server 死，整机重启
#
# 结论：**伪装文件的 SELinux 类型必须与真文件一致（config_gz）**，
# 否则 system_server 必崩。chcon 做不到（策略拒绝），`mount --bind -o context=`
# 也不生效；唯一可行的是 **tmpfs 挂载时带 context=**（类型随挂载点继承）。
#
# 因此本脚本的硬性纪律：
#   1. 用 tmpfs + context= 造出 config_gz 类型的暂存文件；
#   2. **挂载前后各验证一次标签**，任何一次不符就回滚并放弃伪装；
#   3. 宁可伪装失败（App 显示 userns 不可用），也绝不让错类型的文件
#      盖在 /proc/config.gz 上 —— 那会崩系统。
# ═══════════════════════════════════════════════════════════════════════

MODDIR=${0%/*}/..
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/Droidspaces-6.6

SRC=/proc/config.gz
STAGE="$MODDIR/.cfgtmp"          # tmpfs 挂载点（带 config_gz 上下文）
FAKE="$STAGE/config.gz"
WANT_CTX="u:object_r:config_gz:s0"

# 真文件不在就没什么可伪装的
[ -f "$SRC" ] || exit 0

# 已经是我们的挂载（标签正确）就直接退出，避免反复 umount/mount
if mountpoint -q "$SRC" 2>/dev/null; then
	cur=$(ls -Zd "$SRC" 2>/dev/null | awk '{print $1}')
	if [ "$cur" = "$WANT_CTX" ]; then
		exit 0
	fi
	# 是挂载点但类型不对 —— 可能是别人挂的，也可能是旧版本留下的雷。
	# 先拆掉：错类型的 config.gz 会让 system_server 崩，不能留着。
	umount "$SRC" 2>/dev/null
fi

# 内核本来就两项都有 → 根本不需要伪装，更不该去碰 /proc/config.gz
real=$(zcat "$SRC" 2>/dev/null | grep -E '^CONFIG_(USER_NS|DEVTMPFS)=y$' | wc -l)
if [ "$real" -ge 2 ]; then
	umount "$STAGE" 2>/dev/null
	exit 0
fi

# ---------- 1. 造暂存文件（必须带 config_gz 类型） ----------
# 复用已挂载的 tmpfs，省一次挂载
if ! mountpoint -q "$STAGE" 2>/dev/null; then
	mkdir -p "$STAGE" 2>/dev/null
	mount -t tmpfs -o "size=512k,mode=755,context=$WANT_CTX" tmpfs "$STAGE" 2>/dev/null
fi
if ! mountpoint -q "$STAGE" 2>/dev/null; then
	# tmpfs 起不来（无权限 / 内核不支持）→ 放弃伪装，绝不退化成错误类型的 bind
	rmdir "$STAGE" 2>/dev/null
	echo "config.gz: 无法创建 config_gz 类型的暂存区，放弃伪装（userns 将显示不可用）"
	exit 0
fi

zcat "$SRC" 2>/dev/null |
	sed -e 's/^# CONFIG_USER_NS is not set$/CONFIG_USER_NS=y/' \
	    -e 's/^# CONFIG_DEVTMPFS is not set$/CONFIG_DEVTMPFS=y/' |
	gzip -c >"$FAKE.tmp" 2>/dev/null
if [ ! -s "$FAKE.tmp" ]; then
	rm -f "$FAKE.tmp"
	echo "config.gz: 生成失败（原配置读不到），放弃伪装"
	exit 0
fi
mv -f "$FAKE.tmp" "$FAKE"
chmod 444 "$FAKE" 2>/dev/null

# ---------- 2. 挂载前验证：类型必须是 config_gz ----------
got=$(ls -Zd "$FAKE" 2>/dev/null | awk '{print $1}')
if [ "$got" != "$WANT_CTX" ]; then
	echo "config.gz: 暂存文件类型是 '$got'（期望 $WANT_CTX），放弃伪装"
	rm -f "$FAKE"
	exit 0
fi

# ---------- 3. 覆盖 /proc/config.gz ----------
if ! mount --bind "$FAKE" "$SRC" 2>/dev/null; then
	echo "config.gz: bind mount 失败（SELinux 或只读 /proc），放弃伪装"
	rm -f "$FAKE"
	exit 0
fi

# ---------- 4. 挂载后验证：类型仍必须是 config_gz，否则立刻回滚 ----------
got=$(ls -Zd "$SRC" 2>/dev/null | awk '{print $1}')
if [ "$got" != "$WANT_CTX" ]; then
	umount "$SRC" 2>/dev/null
	rm -f "$FAKE"
	echo "config.gz: 挂载后类型是 '$got'（期望 $WANT_CTX），已回滚以免 system_server 崩溃"
	exit 0
fi

# ---------- 5. 内容自检：App 要读的两行确实变成了 y ----------
ok=$(zcat "$SRC" 2>/dev/null | grep -cE '^CONFIG_(USER_NS|DEVTMPFS)=y$')
if [ "$ok" -lt 2 ]; then
	umount "$SRC" 2>/dev/null
	rm -f "$FAKE"
	echo "config.gz: 内容自检失败（只改好 $ok/2 项），已回滚"
	exit 0
fi

echo "config.gz: CONFIG_USER_NS / CONFIG_DEVTMPFS 已标记为 y（类型 $WANT_CTX，已验证）"
exit 0
