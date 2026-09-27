# Alpine Linux for Xiaomi 5 (gemini)

> 本分支（`alpine`）为小米 5 添加 **Alpine Linux** 移植 —— 与 main 分支的 Ubuntu 版共享同一套
> 内核源码、固件与打包流程，仅将用户态换为更轻量的 Alpine（musl + busybox + OpenRC）。
>
> **构建文档： [docs/BUILDING-ALPINE.md](docs/BUILDING-ALPINE.md)**

## 快速开始

1. 打开 [Actions](../../actions) → **Build Alpine Linux for Xiaomi 5 (gemini)**
2. 手动触发（Run workflow）或推送到 `alpine` 分支自动构建
3. 下载 Artifacts：

```
boot-alpine-jdi.img      # JDI 屏 boot 镜像
boot-alpine-lgd.img      # LGD 屏 boot 镜像
rootfs-alpine.simg       # Android sparse 系统镜像
rootfs-alpine-raw.tar.xz # raw ext4 镜像（PC 挂载修改用）
BUILD-INFO.txt
```

4. 刷入：

```bash
fastboot flash boot boot-alpine-jdi.img     # 或 lgd
fastboot flash system rootfs-alpine.simg
fastboot format userdata
```

5. 默认账号 `gemini` / 密码 `1234`，开机自动进入 labwc 桌面（Wayland）。

## 为什么是 Alpine

- **体积**：rootfs ~1.2-1.5GB（Ubuntu 版 ~5GB），musl + busybox + OpenRC 全套基础系统 ~150MB
- **内存**：图形会话下 ~300MB（Ubuntu 版 ~800MB），给 3GB 内存的小米 5 留出更多余量
- **图形**：labwc（wlroots）+ foot + fuzzel + mesa(msm_dri)，Adreno 530 硬件加速
- **兼容**：与 main 分支 Ubuntu 版相同的 6.3.1 内核、DTB、固件、mkbootimg 参数与刷机方式

## 与 main 分支的关系

| | main (Ubuntu 24.04) | alpine (Alpine 3.22) |
|---|---|---|
| 内核 | 6.3.1 msm8996-mainline（仓库内） | 同左（完全一致） |
| 固件 | 仓库 firmware/（LFS） | 同左 |
| 用户态 | systemd + glibc + NetworkManager | OpenRC + musl + iwd |
| 桌面 | 可选大而全 | labwc 最小集 |
| 构建产物 | rootfs-noble.img + boot-{jdi,lgd}.img | rootfs-alpine.simg + boot-alpine-{jdi,lgd}.img |

两个分支互不干扰，工作流按分支与路径过滤自动触发。
