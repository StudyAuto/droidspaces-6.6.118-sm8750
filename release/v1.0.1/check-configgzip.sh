#!/bin/sh
# /proc/config.gz 伪装的安全守卫
#
# 背景（2026-11-03 线上故障）：
#   fake_config.sh 把 /data/adb 下的文件 bind 到 /proc/config.gz，但那个文件的
#   SELinux 类型是 adb_data_file。system_server（uid 1000）读不到 →
#   MemInfoReader.getKernelUsedSizeKb → Debug.isVmapStack() 的硬断言失败 →
#   LOG(FATAL) "Kernel configs could not be fetched. b/151092221" → SIGABRT →
#   system_server 死 → 整机重启。
#
#   而且用户当时已经写了 no_boot 并禁用了模块，post-fs-data.sh 正确跳过了，
#   但 service.sh 在最前面无条件执行 fake_config.sh —— 用户的"关闭"根本没生效。
#
# 本脚本把这两条变成可自动检查的断言，接在打包流程里，防止回归。

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DSM="$ROOT/dsm"
FAIL=0

fail() { echo "✗ $*"; FAIL=1; }
ok()   { echo "✓ $*"; }

FC="$DSM/tools/fake_config.sh"
SV="$DSM/service.sh"

# ── 1. 伪装文件必须是 config_gz 类型：只能靠 tmpfs + context= 拿到 ──────────
[ -f "$FC" ] || fail "缺少 tools/fake_config.sh"

if grep -q 'context=.*config_gz' "$FC" 2>/dev/null; then
	ok "fake_config: 用 tmpfs context= 设置 config_gz 类型"
else
	fail "fake_config: 未见 tmpfs context=config_gz —— 换回 chcon/bind 会导致 system_server 崩溃"
fi

# ── 2. 绝不能只靠 chcon（ksu 域无 relabel 权限，会静默失败） ────────────────
# 只看未被注释掉的行；旧版写法是 `[ -n "$CTX" ] && chcon "$CTX" "$DST"`。
# 注意：POSIX ERE 不支持 \s，必须用 [[:space:]]。
if grep -E '^[[:space:]]*[^#]*chcon[[:space:]]+"?\$?CTX' "$FC" 2>/dev/null | grep -q .; then
	fail "fake_config: 仍在用 chcon 改 config.gz 标签（策略会拒绝，且曾因此崩系统）"
else
	ok "fake_config: 未依赖 chcon"
fi

# ── 3. 挂载前后都必须验证标签，不符要回滚 ──────────────────────────────────
if grep -q 'WANT_CTX' "$FC" 2>/dev/null &&
   [ "$(grep -c 'got.*!=.*WANT_CTX\|got" != "$WANT_CTX' "$FC" 2>/dev/null || echo 0)" -ge 2 ]; then
	ok "fake_config: 挂载前 + 挂载后各验证一次类型（失败即回滚）"
else
	fail "fake_config: 缺少挂载前后的类型校验（错类型挂上就会崩系统）"
fi

# ── 4. service.sh 必须先检查开关，不能无条件改系统状态 ─────────────────────
[ -f "$SV" ] || fail "缺少 service.sh"

if awk '/fake_config\.sh/{found=NR} END{exit 0}' "$SV" 2>/dev/null &&
   [ -n "$(grep -n 'fake_config\.sh' "$SV" 2>/dev/null)" ]; then
	LINE_CFG=$(grep -n 'sh .*fake_config\.sh' "$SV" | head -1 | cut -d: -f1)
	LINE_GATE=$(grep -n 'MODDIR/disable\|MODDIR/no_boot\|MODDIR/blocked' "$SV" | head -1 | cut -d: -f1)
	if [ -n "$LINE_CFG" ] && [ -n "$LINE_GATE" ] && [ "$LINE_GATE" -lt "$LINE_CFG" ]; then
		ok "service.sh: 开关检查在 fake_config 之前（第 ${LINE_GATE} 行 < 第 ${LINE_CFG} 行）"
	else
		fail "service.sh: fake_config 在开关检查之前执行 —— 用户禁用模块后仍会改系统文件"
	fi
else
	ok "service.sh: 未调用 fake_config"
fi

# ── 5. disable 开关本身也要被认（KernelSU 的标准约定） ──────────────────────
if grep -q '\$MODDIR/disable' "$SV" 2>/dev/null; then
	ok "service.sh: 检查了 KernelSU 的 disable 开关"
else
	fail "service.sh: 未检查 disable —— 在管理器里禁用模块后脚本仍会运行"
fi

# ── 6. uninstall 必须把两层挂载都拆掉，否则残留 ────────────────────────────
UN="$DSM/uninstall.sh"
if [ -f "$UN" ]; then
	if grep -q 'umount /proc/config.gz' "$UN" && grep -q '\.cfgtmp' "$UN"; then
		ok "uninstall.sh: bind 与 tmpfs 两层都拆"
	else
		fail "uninstall.sh: 未完整清理 config.gz 挂载（会残留 .cfgtmp）"
	fi
else
	fail "缺少 uninstall.sh"
fi

echo
if [ "$FAIL" = 0 ]; then
	echo "config.gz 安全守卫：全部通过"
	exit 0
fi
echo "config.gz 安全守卫：存在未通过项（见上）"
exit 1
