// 探针：把设备内核的**完整导出符号表 + CRC** 导出成 Module.symvers。
//
// 为什么不再尝试"复现内核构建环境"：
//   设备内核 6.6.118-android15-8-g899dc6830d9c 是第三方基于官方源码编译的，
//   带 KSU/SUSFS/厂商补丁；公开仓库里没有这个 commit，也复现不出同样的
//   struct 布局。实测 module_layout CRC：
//       设备   0x4e276f37
//       我们   0x6500052f   ← 完全不同
//   所以无论怎么调 CONFIG 都编不出能加载的模块。
//
// 正解：设备内核自己的 __kcrctab 就是权威来源。
//   把 __ksymtab（名字/命名空间）与 __kcrctab（CRC，顺序一一对应）读出来，
//   生成一份完全匹配设备的 Module.symvers，再用它编译模块。
//   这样每个导入符号的 CRC 都与设备一致，__versions 校验自然通过。
//
// 原理：CONFIG_HAVE_ARCH_PREL32_RELOCATIONS 下
//   struct kernel_symbol { s32 value_offset; s32 name_offset; s32 namespace_offset; }
//   12 字节；__kcrctab 每项 4 字节，顺序对应。
//
// 安全：只读内核数据段，不引用任何内核结构体、不改状态。
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/fs.h>
#include <linux/file.h>
#include <linux/version.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("export the running kernel export table as Module.symvers");

/* filp_open / kernel_write 在 GKI 里属于受限命名空间，
 * 不写 MODULE_IMPORT_NS 会被 modpost 拒绝。 */
MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);

static unsigned long ksymtab_base;
static unsigned long kcrctab_base;
static unsigned long ksymtab_end;
static char *out_path = "/data/local/tmp/device.symvers";
module_param(ksymtab_base, ulong, 0444);
module_param(kcrctab_base, ulong, 0444);
module_param(ksymtab_end, ulong, 0444);
module_param(out_path, charp, 0444);

#define KSYM_ENTRY 12
#define MAX_SCAN   8192

static int __init crcprobe_init(void)
{
	struct file *f;
	loff_t pos = 0;
	int i, written = 0;

	if (!ksymtab_base || !kcrctab_base || !ksymtab_end) {
		pr_info("CRCPROBE: missing section bases\n");
		return -EINVAL;
	}

	f = filp_open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (IS_ERR(f)) {
		pr_info("CRCPROBE: open %s failed %ld\n", out_path, PTR_ERR(f));
		return -EINVAL;
	}

	for (i = 0; i < MAX_SCAN; i++) {
		unsigned long entry = ksymtab_base + (unsigned long)i * KSYM_ENTRY;
		s32 name_off = 0;
		unsigned long name_addr;
		char name[128];
		u32 crc = 0;
		char line[196];
		int len;

		if (entry + KSYM_ENTRY > ksymtab_end)
			break;

		memset(name, 0, sizeof(name));
		if (copy_from_kernel_nofault(&name_off, (void *)(entry + 4), sizeof(name_off)))
			break;
		name_addr = entry + 4 + (long)name_off;
		if (copy_from_kernel_nofault(name, (void *)name_addr, sizeof(name) - 1))
			continue;
		if (!name[0])
			continue;

		if (copy_from_kernel_nofault(&crc, (void *)(kcrctab_base + (unsigned long)i * 4),
					     sizeof(crc)))
			continue;

		// Module.symvers 格式：CRC \t 名字 \t 模块 \t 导出类型
		len = scnprintf(line, sizeof(line), "0x%08x\t%s\tvmlinux\tEXPORT_SYMBOL\n",
				crc, name);
		if (kernel_write(f, line, len, &pos) == len)
			written++;
	}

	filp_close(f, NULL);
	pr_info("CRCPROBE: wrote %d symbols to %s\n", written, out_path);
	return -EINVAL;
}

module_init(crcprobe_init);
