# Podroid-Debian

[English](./README.en.md) | **简体中文**

**[Podroid](https://github.com/ExTV/Podroid) 的 Debian (arm64) 根文件系统** —— 替换
Podroid 原有的 Alpine `alpine-rootfs.squashfs`，即插即用，**完整保留 guest ↔ Android
的启动契约**（控制台标记、hvc0/hvc1/hvc2、host bridge、端口转发、存储布局）。

Podroid 使用定制的 7.1.5 aarch64 内核 + `init-podroid`（PID 1）：挂载 squashfs
lower + ext4 upper overlay，然后 `switch_root` 进入 `/sbin/init`。本项目提供**基于
systemd 的 Debian rootfs**，接入完全相同的启动流水线，APK 侧代码（QemuEngine /
AvfEngine / BootStageDetector / host bridge）**零改动**。

> 进度：**Phase 2–4 已完成**（构建环境、squashfs 构建、真机安装运行）。
> `graft.sh` 已按 `DESIGN.md §11.2` **废除**：N4 后系统以独立 `.img` 分发，
> APK 不再内置 rootfs。更多见 [docs/PLAN.md](docs/PLAN.md)。

## 为什么选 Debian（而不是 "Linux Mint"）

Linux Mint 不提供 ARM 镜像，而本 VM 只支持 aarch64（QEMU `--target-list=aarch64-softmmu`）。
Debian arm64 正是 Mint 的上游基底，拥有 apt 生态、systemd 和完整容器栈所需软件包。
Alpine → Debian 的对应关系见 [docs/DELTAS.md](docs/DELTAS.md)。

## 目录结构

```
build/          构建流水线（docker 路径 + 本地 root 路径）
  build-rootfs.sh      入口：--check | docker | local
  Dockerfile.rootfs    arm64 容器构建（需要 binfmt/qemu-user）
  local-rootfs.sh      debootstrap 路径（需要 root + qemu-user-static）
  rootfs-finalize.sh   chroot 内统一装配（单元、密码、清理）
  build-native.sh      交叉编译 guest C 程序（aarch64 静态）
  packages.list        apt 包集合（容器 + 基础 + X11）
  packages-desktop.list  可选桌面配置（实验性）
rootfs/         原样拷入镜像的 overlay
  etc/systemd/system/  systemd 单元，替代 Alpine 的 openrc podroid-* 脚本
  etc/podroid/         forwards.conf、migrations/
  usr/local/lib/podroid/  移植的启动脚本（启动逻辑逐行保留）
  usr/local/bin/       getty/login/resize 辅助（契约与上游一致）
tests/          回归测试（DNS 解析顺序，移植自上游）
tools/          mkimg.sh（打包/校验 .img）、catalog.sh、pc-boot-smoke.sh、boot-test.sh（adb 冒烟）
docs/           PLAN / COMPAT / DELTAS
native/         交叉编译产物（hostd、vsock-agent、overlay-normalize，aarch64 静态）
```

## 快速开始

```sh
# 1. 检查本机构建条件
./build/build-rootfs.sh --check

# 2. 构建（docker + arm64 binfmt，或 root + qemu-user-static）
./build/build-rootfs.sh
#    -> out/debian-rootfs.squashfs

# 3. 打包 .img（R-16 要求自带 kernel/initrd payload；DESIGN §2/§6）
tools/mkimg.sh --rootfs out/debian-rootfs.squashfs --manifest <manifest.json> \
               --kernel <vmlinuz> --initrd <initrd.img> -o out/debian.img
#    注：graft.sh 已按 DESIGN §11.2 废除（APK 不再内置 rootfs，系统以 .img 分发）

# 4. 把 .img 导入 App（引导页/镜像页"从文件导入"或 catalog 下载），
#    在 Home 启动镜像选择控件（DESIGN §8.2）激活后启动

# 5. adb 冒烟测试：轮询 console.log 中的 "Ready!"（脚本自建 adb forward tcp:9922）
./tools/boot-test.sh                      # 默认 PKG=io.github.ltbkq.vmdroid.debug
./tools/boot-test.sh <other.pkg.debug>    # 或位置参数指定其他包名
```

## 默认凭据（DESIGN §4.8）

| 用户 | 密码 |
|------|------|
| `root` | **`123`** |
| `ltbkq` | **`123`**（免密 sudo） |

```sh
adb forward tcp:9922 tcp:9922
ssh ltbkq@localhost -p 9922       # 密码：123
ssh root@localhost -p 9922        # 密码：123
```

> 上游 Alpine rootfs 的密码是 `podroid`；2026-10-07 应维护者要求改为 `123`，
> 取值处：`build/rootfs-finalize.sh`。

## 硬性要求

- VM 沿用 Podroid **定制内核**（全量 builtin，无 `/lib/modules`，与上游 Alpine 假设一致）。
- 从 Alpine 升级时**必须清空 overlay upper**（首次启动执行 `Reset VM`），
  否则 Alpine 的 copy-up 文件会遮蔽 Debian rootfs。
- 资产文件名保持 `alpine-rootfs.squashfs`，Kotlin 代码无需任何修改
  （`PodroidApplication.kt:107`、`QemuEngine.kt:575`、`AvfEngine.kt:1027`）。

## 许可证

GPLv2，与 Podroid 相同。启动脚本移植自 ExTV/Podroid 的 openrc 脚本
（原始逻辑完整保留并以注释标注）。
