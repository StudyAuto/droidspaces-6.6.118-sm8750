// 探针：读出设备内核真实的 module_layout CRC，用于比对我们的构建是否匹配。
//
// 为什么需要它：模块加载时内核只对 module_layout 做强校验
// （"disagrees about version of symbol module_layout"）。
// 但设备内核的 CRC 表在内存里，没有 /proc/kcore，kallsyms 也隐藏了地址，
// 用户态拿不到。唯一可行的是让一段内核代码自己读。
//
// 本模块刻意**不碰任何内核结构体**：只取一个导出符号的地址并打印。
// 这样即使布局不匹配也不会 panic（上次 droid_lkm_misc 那样）。
#include <linux/module.h>
#include <linux/kernel.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("read the running kernel's module_layout CRC");

// 内核自身持有的 CRC，由 CONFIG_MODVERSIONS 生成在 __kcrctab
extern unsigned long __crc_module_layout;

static int __init crcprobe_init(void)
{
	// 打印出来给 dmesg 抓；返回值非 0 让它自己退出，不在系统里驻留
	pr_info("CRCPROBE: module_layout_crc=0x%08lx\n", __crc_module_layout);
	return -EINVAL;
}

module_init(crcprobe_init);
