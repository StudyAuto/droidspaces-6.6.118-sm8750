// 探针：读出设备内核真实的 module_layout CRC。
//
// 背景：模块加载时内核只对 module_layout 做强校验
//   "disagrees about version of symbol module_layout"
// 设备内核的 CRC 表在内存里，但没有 /proc/kcore，kallsyms 也只给出
// module_layout 的函数地址而非 CRC。用户态拿不到，只能让内核代码读。
//
// 为什么用模块参数传地址：
//   kallsyms_lookup_name 在新内核不导出（modpost 会报 undefined），
//   __crc_module_layout 也不是导出符号。但用户态能以 root 读
//   /proc/kallsyms（kptr_restrict=0 时拿得到真实地址），
//   把 __start___ksymtab / __start___kcrctab 的基址作为参数传进来即可。
//   探针只依赖已导出的 copy_from_kernel_nofault。
//
// 原理：CONFIG_HAVE_ARCH_PREL32_RELOCATIONS 下
//   struct kernel_symbol { s32 value_offset; s32 name_offset; s32 namespace_offset; }
// 12 字节，按导出顺序排在 __ksymtab；__kcrctab 每项 4 字节，顺序一一对应。
// 找到名为 module_layout 的下标 i，__kcrctab[i] 就是它的 CRC。
//
// 安全：只读内核数据段，不引用任何内核结构体、不改任何状态。
// 即使配置不匹配也不会 panic（区别于 droid_lkm_misc 那种操作结构体的模块）。
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/uaccess.h>
#include <linux/string.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("read the running kernel module_layout CRC");

static unsigned long ksymtab_base;
static unsigned long kcrctab_base;
module_param(ksymtab_base, ulong, 0444);
module_param(kcrctab_base, ulong, 0444);
MODULE_PARM_DESC(ksymtab_base, "__start___ksymtab from /proc/kallsyms");
MODULE_PARM_DESC(kcrctab_base, "__start___kcrctab from /proc/kallsyms");

#define KSYM_ENTRY 12
#define MAX_SCAN   8192

static int __init crcprobe_init(void)
{
	int i, found = -1;

	if (!ksymtab_base || !kcrctab_base) {
		pr_info("CRCPROBE: missing params ksymtab_base/kcrctab_base\n");
		return -EINVAL;
	}
	pr_info("CRCPROBE: ksymtab=0x%lx kcrctab=0x%lx\n", ksymtab_base, kcrctab_base);

	for (i = 0; i < MAX_SCAN; i++) {
		s32 name_off = 0;
		unsigned long entry = ksymtab_base + (unsigned long)i * KSYM_ENTRY;
		unsigned long name_addr;
		char name[32];

		memset(name, 0, sizeof(name));
		if (copy_from_kernel_nofault(&name_off, (void *)(entry + 4), sizeof(name_off)))
			break;
		name_addr = entry + 4 + (long)name_off;
		if (copy_from_kernel_nofault(name, (void *)name_addr, sizeof(name) - 1))
			continue;
		if (!memcmp(name, "module_layout", 13)) {
			found = i;
			break;
		}
	}

	if (found < 0) {
		pr_info("CRCPROBE: module_layout not found in ksymtab\n");
		return -EINVAL;
	}

	{
		u32 crc = 0;
		unsigned long crc_addr = kcrctab_base + (unsigned long)found * 4;
		if (copy_from_kernel_nofault(&crc, (void *)crc_addr, sizeof(crc)))
			pr_info("CRCPROBE: read crc failed at 0x%lx\n", crc_addr);
		else
			pr_info("CRCPROBE: index=%d module_layout_crc=0x%08x\n", found, crc);
	}

	return -EINVAL;
}

module_init(crcprobe_init);
