# Release 说明

本目录存放**二进制交付物**，每个版本一个子目录。

zip 里含完整 KernelSU 模块（`module.prop` + 脚本 + `ko/` + `webroot/`）；
单文件是方便快速替换的散件。校验和见仓库根 [`checksums.txt`](../checksums.txt)。

---

## v1.0.1-6.6（当前版本）— **安全修复，必须升级**

> ⚠️ **v1.0.0 有一个会导致整机反复重启的严重 bug，请勿使用。**
> `fake_config.sh` 把 `/proc/config.gz` 换成的文件 SELinux 类型错误（`adb_data_file`
> 而非 `config_gz`），`system_server` 读不到就触发 AOSP 硬断言
> （`Kernel configs could not be fetched. b/151092221`）→ SIGABRT → 整机重启。
> 而且 `service.sh` 会无视 `no_boot` / `disable`，用户"关掉模块"也没用。
> 详见 [`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md) ⑤ 与 [`CHANGELOG.md`](../CHANGELOG.md)。

| 文件 | 大小 | md5 | 用途 |
|---|---|---|---|
| `Droidspaces-v1.0.1-6.6.zip` | 5.9 MB | `2849ad741ef2146f90858873eec91d51` | 完整包，KernelSU 刷入 |
| `droid_lkm_misc.ko` | 3.5 MB | `c835b721a16fa2d7df72ef856b84112f` | 单独的内核模块 |
| `index.html` | 80 KB | `9aca82f8ccd2854de422f6fae2d7b768` | WebUI 页面 |
| `setup-docker.sh` | 4.2 KB | `bd696461ad4df6b7cd6ae28dd5a5588c` | 容器内 Docker 一键配置 |
| `fake_config.sh` | 5.8 KB | `fc2fcbbcba7edc24ef98ce3d6a036091` | 伪装 config.gz（**本版已修 SELinux 类型**） |
| `service.sh` | 2.1 KB | `422463089982556e300bc722a49e7e41` | 存活确认（**本版已尊重 no_boot/disable**） |
| `uninstall.sh` | 1.5 KB | `0178518dba430fe6f8af43dec9364781` | 卸载清理（**本版补齐两层挂载**） |
| `check-webui.sh` | 3.0 KB | `5e2e52bef6791100fd8f4cdd44d6ec3d` | WebUI 语法/DOM 守卫 |
| `check-configgzip.sh` | 4.2 KB | `1aed4b0f8f26e6d4c52b4d87c6a38d32` | config.gz 安全守卫（新增） |

本版修复验证（真机 2026-11-03）：

- 伪装后 `/proc/config.gz` 标签为 `u:object_r:config_gz:s0`（与真文件一致）
- 内容两项均为 `y`，普通进程可读
- **system_server 存活，无新崩溃**

---

## v1.0.0-6.6（**已废弃，勿用** —— 会崩系统）

| 文件 | 大小 | md5 | 用途 |
|---|---|---|---|
| `Droidspaces-v1.0.0-6.6.zip` | 5.9 MB | `b6367f496ebbb9780b72e1875647ce35` | 完整包，KernelSU 刷入 |
| `droid_lkm_misc.ko` | 3.5 MB | `c835b721a16fa2d7df72ef856b84112f` | 单独的内核模块 |
| `index.html` | 80 KB | `9aca82f8ccd2854de422f6fae2d7b768` | WebUI 页面 |
| `setup-docker.sh` | 4.2 KB | `bd696461ad4df6b7cd6ae28dd5a5588c` | 容器内 Docker 一键配置 |
| `check-webui.sh` | 3.0 KB | `5e2e52bef6791100fd8f4cdd44d6ec3d` | WebUI 语法/DOM 守卫 |
| `userns.sh` | 12 KB | `0f8dec4c61153209b45e0e8ddb90b403` | 属主脚本（含护栏） |
| `fake_config.sh` | 2.1 KB | `5d0afd1035f97a4d54213dc35ce6ba87` | 伪装 config.gz（见 README） |

目标：**一加 13（PJZ110 / OP5D0DL1）** / `6.6.118-android15-8-...-lotus-4k`

真机验证（2026-11-03）：

- 6 个模块 `insmod` 全部 rc=0
- 布局自校验 62 项 `live == build`
- pid / ipc namespace、devtmpfs、pids 显示层、macvlan、ip6tables nat 全部确认

> zip 里的 README / 教程是打包当天的快照。之后文档有更新只改仓库，
> 不重打包 —— 重打包会改 md5，反而让 `checksums.txt` 对不上。
> 看文档一律以仓库为准。

---

## 校验下载的文件

```sh
md5sum -c checksums.txt --ignore-missing
```
