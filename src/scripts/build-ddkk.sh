#!/bin/sh
# 编译主模块：droid_lkm / droid_lkm_vendor / droid_lkm_misc / droid_lkm_pids
#
# 用法: sh scripts/build-ddkk.sh [target]
#   target 默认 android15-6.6（本项目唯一验证过的目标）
#
# 为什么是 android15-6.6：
#   目标机型 SM8750（一加 13 / OP5D0DL1）出厂内核是
#     6.6.118-android15-8-g899dc6830d9c-abogki500782043-lotus-4k
#   它是 GKI KMI android15-6.6，模块必须用该 KMI 的 KDIR + 同版本 clang 编。
#
# 关于 vermagic 6.6.127 vs 6.6.118：
#   DDK 镜像自带的 KDIR 是 6.6.127，编出来的 ko 里 vermagic 首段因此是
#   "6.6.127-4k-g...-dirty"。加载时内核的 same_magic() 在模块带 __versions
#   crc（CONFIG_MODVERSIONS=y）时**跳过首段、只比较空格后的部分**，
#   所以 6.6.127 编的 ko 可以直接 insmod 进 6.6.118。
#   真机已验证（见 docs/BUILD.md §"验证"）。
#
# VER 决定 KMI 选择与输出目录，必须与目标内核一致。
# 产物: droid_lkm/out/<target>/{droid_lkm,droid_lkm_vendor,droid_lkm_misc,droid_lkm_pids}.ko
set -e

TARGET=${1:-android15-6.6}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRCDIR="$ROOT/droid_lkm"

# 两种运行方式，按是否存在 docker 自动选：
#   A) docker run（原版路径，需要 DDK 镜像）
#   B) 直接调用 DDK 镜像解包出来的 toolchain（runroot 模式）
#      环境变量 DDK_ROOT 指向解包后的根目录，内含
#      $DDK_ROOT/opt/ddk/{kdir,src,clang}
DDK_ROOT=${DDK_ROOT:-}
IMAGE=${DDK_IMAGE:-docker.cnb.cool/ylarod/ddk/ddk-min:${TARGET}}

echo "==> target=${TARGET}"

run_in_ddk() {
	# $1 = 要在 DDK 环境里执行的 shell 片段
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
			-e DROID_LKM_LAYOUT_FALLBACK \
			-e DROID_LKM_LAYOUT_FORCE_BUILD \
			-e DROID_LKM_LAYOUT_MANUAL \
			-e DROID_LKM_LAYOUT_TEST_BUILD_SHIFT \
			-v "$SRCDIR":/src \
			-w /src \
			"$IMAGE" \
			sh -c "$1"
	fi
}

# DDK_ROOT 模式下源码要出现在 rootfs 里，先同步一份
if [ -n "$DDK_ROOT" ]; then
	rm -rf "$DDK_ROOT/src"
	mkdir -p "$DDK_ROOT/src"
	cp -a "$SRCDIR"/. "$DDK_ROOT/src"/
fi

run_in_ddk "cd /src && make VER=$TARGET KDIR=/opt/ddk/kdir/$TARGET -j\$(nproc)"

OUTDIR="$SRCDIR/out/$TARGET"
if [ -n "$DDK_ROOT" ]; then
	# chroot 里编出来的 out/ 在 rootfs 里，搬回源码树
	rm -rf "$OUTDIR"
	mkdir -p "$(dirname "$OUTDIR")"
	cp -a "$DDK_ROOT/src/out/$TARGET" "$OUTDIR"
fi

echo "==> 产物"
find "$OUTDIR" -name "*.ko"

echo "==> 拷到 dsm/ko/ 供打包"
mkdir -p "$ROOT/dsm/ko"
for k in droid_lkm droid_lkm_vendor droid_lkm_misc droid_lkm_pids; do
	[ -f "$OUTDIR/$k.ko" ] && cp "$OUTDIR/$k.ko" "$ROOT/dsm/ko/$k.ko"
done
echo "BUILD_LKM_DONE"
