// 探针：把设备内核的完整导出符号表 + CRC 导出，供用户态读走。
//
// 为什么需要（前一轮实测已确认）：
//   设备 module_layout CRC = 0x4e276f37
//   我们编译出来的       = 0x6500052f   ← 完全不同
// 设备内核是第三方基于官方源码 + KSU/SUSFS/厂商补丁编的，公开仓库里
// 没有对应 commit，struct 布局复现不出来。所以不再尝试复现构建环境，
// 改为直接读设备内核自己的 __kcrctab —— 那是权威来源。
//
// 为什么用 proc 节点而不是直接写文件：
//   filp_open / kernel_write 在 GKI 上属于受限命名空间且可能未被导出
//   （实测 insmod 报 "Unknown symbol filp_open err -2"）。
//   proc_create + seq_printf 是模块读数据给用户态的标准做法，符号可用。
//
// 原理：CONFIG_HAVE_ARCH_PREL32_RELOCATIONS 下
//   struct kernel_symbol { s32 value_offset; s32 name_offset; s32 namespace_offset; }
//   12 字节，按导出顺序排在 __ksymtab；__kcrctab 每项 4 字节，顺序一一对应。
//
// 安全：只读内核数据段，不引用任何内核结构体、不改任何状态。
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("export the running kernel export table with CRCs");

static unsigned long ksymtab_base;
static unsigned long ksymtab_end;
static unsigned long kcrctab_base;
module_param(ksymtab_base, ulong, 0444);
module_param(ksymtab_end, ulong, 0444);
module_param(kcrctab_base, ulong, 0444);

#define KSYM_ENTRY 12
#define MAX_SCAN   8192

static int crcprobe_show(struct seq_file *m, void *v)
{
	int i;
	int n = 0;

	for (i = 0; i < MAX_SCAN; i++) {
		unsigned long entry = ksymtab_base + (unsigned long)i * KSYM_ENTRY;
		s32 name_off = 0;
		unsigned long name_addr;
		char name[128];
		u32 crc = 0;

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

		if (copy_from_kernel_nofault(&crc,
				(void *)(kcrctab_base + (unsigned long)i * 4), sizeof(crc)))
			continue;

		/* Module.symvers 格式：CRC \t 名字 \t 模块 \t 导出类型 */
		seq_printf(m, "0x%08x\t%s\tvmlinux\tEXPORT_SYMBOL\n", crc, name);
		n++;
	}
	seq_printf(m, "# total %d entries\n", n);
	return 0;
}

static int crcprobe_open(struct inode *inode, struct file *file)
{
	return single_open(file, crcprobe_show, NULL);
}

static const struct proc_ops crcprobe_pops = {
	.proc_open	= crcprobe_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static struct proc_dir_entry *crcprobe_entry;

static int __init crcprobe_init(void)
{
	if (!ksymtab_base || !ksymtab_end || !kcrctab_base) {
		pr_info("CRCPROBE: missing section bases\n");
		return -EINVAL;
	}
	crcprobe_entry = proc_create("crcprobe", 0444, NULL, &crcprobe_pops);
	if (!crcprobe_entry) {
		pr_info("CRCPROBE: proc_create failed\n");
		return -EINVAL;
	}
	pr_info("CRCPROBE: ready, read /proc/crcprobe\n");
	return 0; /* 驻留，供用户态读取；用完 rmmod */
}

static void __exit crcprobe_exit(void)
{
	if (crcprobe_entry)
		proc_remove(crcprobe_entry);
}

module_init(crcprobe_init);
module_exit(crcprobe_exit);
