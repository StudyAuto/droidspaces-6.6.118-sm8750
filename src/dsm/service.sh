#!/system/bin/sh
# late_start service —— 存活确认
#
# post-fs-data.sh 加载成功后留下 boot_pending；本脚本等 120 秒，
# 若系统还活着就写 .boot_ok 并把 boot_pending 删掉。
# 下次开机若看到 boot_pending 还在、.boot_ok 不在，说明上次是"加载完才崩"
# （insmod 成功但几十秒后 panic），post-fs-data.sh 会据此建 blocked 跳过加载。
#
# 这一段补的是 insmod.inflight 覆盖不到的窗口：那种"能开机、用一会儿才崩"的情况。
#
# 存活窗口可用存活文件改: echo 300 > /data/adb/modules/Droidspaces-6.6/alive_sec

MODDIR=${0%/*}

# ⚠️ 开关必须在这里最先检查（2026-11-03 修）。
# 旧版把 fake_config.sh 放在最前面无条件执行，结果：
#   用户写了 no_boot / 在管理器里禁用了模块
#   → post-fs-data.sh 正确跳过（history.log 有 "BOOT SKIP (no_boot)"）
#   → 但本脚本照样把 /proc/config.gz 挂掉 → system_server 崩 → 整机重启。
# 用户以为"我已经关了模块"，实际模块仍在改动系统文件。
# 任何「改系统状态」的动作都必须先过这三道开关，一条都不能少。
NEED_CFG=1
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/no_boot" ] || [ -f "$MODDIR/blocked" ]; then
	NEED_CFG=0
fi

# App 可能在任何时候重新探测内核能力，挂载被拆掉的话这里补回来。
# 只在「模块确实启用且要加载」时才做 —— 伪装 /proc/config.gz 有崩系统风险，
# 不能为了界面好看而在用户已关闭模块时偷偷挂上。
[ "$NEED_CFG" = 1 ] && [ -f "$MODDIR/tools/fake_config.sh" ] &&
	sh "$MODDIR/tools/fake_config.sh" >/dev/null 2>&1

PEND="$MODDIR/boot_pending"

[ -f "$PEND" ] || exit 0

SEC=120
if [ -f "$MODDIR/alive_sec" ]; then
  V=$(tr -dc '0-9' <"$MODDIR/alive_sec" 2>/dev/null)
  [ -n "$V" ] && [ "$V" -gt 0 ] && [ "$V" -le 900 ] && SEC=$V
fi

sleep "$SEC"

# 已经被守卫拦下或用户已恢复, 不重复标记
[ -f "$MODDIR/blocked" ] && { rm -f "$PEND" 2>/dev/null; exit 0; }

: >"$MODDIR/.boot_ok" 2>/dev/null
rm -f "$PEND" 2>/dev/null
exit 0
