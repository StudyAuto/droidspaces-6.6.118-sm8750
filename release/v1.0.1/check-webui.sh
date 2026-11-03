#!/bin/sh
# WebUI 语法守卫 —— 打包前必须通过
#
# 为什么需要：index.html 里的 JS 一旦有语法错误，整段脚本不会执行，
# 页面会永久停在初始占位文字（「检测中」「读取中…」），
# 而且没有任何报错提示 —— 在手机上极难发现。
#
# 本仓库 2026-11-03 就踩过一次：改 userns 开关逻辑时把一个函数结尾的
# `}` 误写成 `});`，导致「模块状态」一直显示「检测中」。
#
# 用法: sh scripts/check-webui.sh
#       （package-ksu-zip.sh 会自动调用）
#
# 依赖：node（有就用，没有就退化成括号平衡检查）

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HTML="$ROOT/dsm/webroot/index.html"
[ -f "$HTML" ] || { echo "缺少 $HTML"; exit 1; }

TMP=$(mktemp /tmp/dswebui.XXXXXX.js)
trap 'rm -f "$TMP"' EXIT

# 抽出所有 <script> 块。注意只用 sed 做块提取，不做任何转义，
# 保持原文语义（任何改写都可能掩盖真实语法错误）。
awk '
	/<script[^>]*>/ { inside=1; sub(/.*<script[^>]*>/, ""); if ($0 != "") print; next }
	/<\/script>/   { if (inside) { sub(/<\/script>.*/, ""); if ($0 != "") print; inside=0 }; next }
	inside         { print }
' "$HTML" >"$TMP"

[ -s "$TMP" ] || { echo "没找到 <script> 块"; exit 1; }

if command -v node >/dev/null 2>&1; then
	if node --check "$TMP" 2>/tmp/dswebui.err; then
		echo "webui 语法 OK ($(wc -l <"$TMP") 行 JS)"
		# 语法过了还不够：引用不存在的 id 会在运行时抛 TypeError，
		# doStatus 一中断整页状态就永久停在「检测中」，比语法错误更难查。
		if command -v python3 >/dev/null 2>&1; then
			python3 - "$HTML" "$TMP" <<'PY2' || exit 1
import re, sys
html = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
js = open(sys.argv[2], encoding='utf-8', errors='ignore').read()
ids = set(re.findall(r'id="([^"]+)"', html))
missing = []
for m in re.finditer(r'document\.getElementById\("([^"]+)"\)\s*\.', js):
    if m.group(1) not in ids:
        missing.append((js[:m.start()].count(chr(10)) + 1, m.group(1)))
if missing:
    print('✗ 引用了 HTML 中不存在的 id（运行期会抛 TypeError，页面停在「检测中」）：')
    for line, name in missing:
        print(f'   js 第 {line} 行: #{name}')
    sys.exit(1)
print('webui DOM 引用 OK（%d 个 id 全部存在）' % len(ids))
PY2
		fi
		exit 0
	fi
	echo "✗ WebUI 有 JS 语法错误（页面会一直停在「检测中」）："
	cat /tmp/dswebui.err
	exit 1
fi

# 没有 node：退化成括号平衡检查（去掉字符串与注释后计数）
echo "（没有 node，退化为括号检查）"
if command -v python3 >/dev/null 2>&1; then
	python3 - "$TMP" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
def strip(t):
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)
    t = re.sub(r'//[^\n]*', '', t)
    t = re.sub(r'`(?:[^`\\]|\\.)*`', '``', t, flags=re.S)
    t = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', t)
    t = re.sub(r"'(?:[^'\\\n]|\\.)*'", "''", t)
    return t
t = strip(src)
bad = False
for o, c, name in [('{', '}', 'brace'), ('(', ')', 'paren'), ('[', ']', 'bracket')]:
    d = t.count(o) - t.count(c)
    if d:
        print(f'✗ {name} 不平衡：{d:+d}')
        bad = True
if bad:
    sys.exit(1)
print('webui 括号平衡 OK（未做完整语法检查，建议装 node）')
PY
	exit $?
fi

echo "既没有 node 也没有 python3，跳过检查"
exit 0
