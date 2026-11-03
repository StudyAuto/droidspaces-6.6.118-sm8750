#!/bin/sh
# 用 Android DDK 工具链编译两个网络扩展模块：macvlan.ko / ip6table_nat.ko
#
# 为什么必须用 DDK：
#   目标内核 (6.6.118-android15-8-...-lotus-4k) 开启了 CONFIG_CFI_CLANG=y（KCFI），
#   模块函数的类型签名必须与内核编译时逐字节一致，否则 insmod 时内核报
#   "CFI failure at do_one_initcall" 并直接关机。
#   DDK 镜像内置匹配该 KMI 的 clang（r510928，与设备原厂同一版本）
#   + KDIR(android15-6.6)。用别的 clang 编出来的模块 insmod 会关机。
#
# 用法: sh build-net-ddk.sh [target]
#   target 默认 android15-6.6
#
# 产物: net_macvlan/macvlan.ko, net_ip6nat/ip6table_nat.ko
set -e

TARGET=${1:-android15-6.6}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DDK_ROOT=${DDK_ROOT:-}
IMAGE=${DDK_IMAGE:-docker.cnb.cool/ylarod/ddk/ddk-min:${TARGET}}

echo "==> target=${TARGET}"

run_in_ddk() {
	if [ -n "$DDK_ROOT" ]; then
		command -v chroot >/dev/null 2>&1 || {
			echo "需要 chroot（root 权限）才能用 DDK_ROOT 模式"; exit 1; }
		chroot "$DDK_ROOT" /bin/bash -c "
			export PATH=/opt/ddk/clang/clang-r510928/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
			export LD_LIBRARY_PATH=/opt/ddk/clang/clang-r510928/lib
			export ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu-
			$1"
	else
		docker run --rm \
			-e KDIR=/opt/ddk/kdir/${TARGET} \
			-v "$ROOT/$2":/$2 \
			-w /$2 \
			"$IMAGE" \
			sh -c "$1"
	fi
}

for m in net_macvlan net_ip6nat; do
	echo "==> build ${m}"
	if [ -n "$DDK_ROOT" ]; then
		rm -rf "$DDK_ROOT/$m"
		cp -a "$ROOT/$m" "$DDK_ROOT/$m"
	fi
	run_in_ddk "make -C /opt/ddk/kdir/$TARGET M=/$m clean >/dev/null 2>&1; make -C /opt/ddk/kdir/$TARGET M=/$m modules" "$m"
	if [ -n "$DDK_ROOT" ]; then
		# chroot 里的产出搬回源码树（.ko 是 gitignore 的构建产物）
		cp -a "$DDK_ROOT/$m"/*.ko "$ROOT/$m"/ 2>/dev/null || true
	fi
done

echo
echo "==> 产物"
ls -la "$ROOT/net_macvlan/macvlan.ko" "$ROOT/net_ip6nat/ip6table_nat.ko"
echo "==> 拷到 dsm/ko/ 供打包"
cp "$ROOT/net_macvlan/macvlan.ko" "$ROOT/dsm/ko/macvlan.ko"
cp "$ROOT/net_ip6nat/ip6table_nat.ko" "$ROOT/dsm/ko/ip6table_nat.ko"
echo "BUILD_NET_DONE"
