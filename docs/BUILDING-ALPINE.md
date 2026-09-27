# Alpine Linux for Xiaomi 5 (gemini) — 构建说明

> 小米 5（codename: **gemini**，高通 msm8996）的 **Alpine Linux** 移植，
> 构建思路与 [Ubuntu_For_Xiaomi5_Gemini](../) 完全一致：
> 仓库内 6.3.1 msm8996-mainline 内核 + debootstrap（此处为 Alpine minirootfs）+ mkbootimg。
> 区别仅在于用户态从 Ubuntu 换成 **Alpine Linux（musl + busybox + openrc）**，
> 体积从 ~5GiB 缩到 ~2GiB（sparse 后 ~600-700MB），内存占用从 ~800MB 降到 ~300MB。

---

## 产物（GitHub Actions 自动构建）

| 文件 | 说明 |
|---|---|
| `boot-alpine-jdi.img` | boot 镜像，适用 **JDI** 屏 |
| `boot-alpine-lgd.img` | boot 镜像，适用 **LGD** 屏 |
| `rootfs-alpine.simg` | Android sparse 镜像，fastboot 刷入 |
| `rootfs-alpine-raw.tar.xz` | 原始 ext4 镜像压缩包，PC 直接挂载修改 |
| `BUILD-INFO.txt` | 构建信息 |

入口: [GitHub Actions → Build Alpine Linux for Xiaomi 5 (gemini)](../../actions) → 手动 Run workflow 或推送 `alpine` 分支自动触发。

---

## 轻量化策略（对应"尽可能轻量，但需要图形界面"）

| 类别 | Ubuntu 版 | Alpine 版 |
|---|---|---|
| C 库 | glibc (~10MB+) | musl (~1MB) |
| init | systemd (~50MB) | OpenRC (~1MB) |
| 桌面 | GNOME / LXQt | **labwc**（最轻 Wayland 合成器, wlroots 基座） |
| 终端 | gnome-terminal | **foot**（原生 Wayland, ~500KB） |
| 启动器 | — | **fuzzel**（~200KB） |
| 显示管理 | gdm3 | **tinydm** + autologin（postmarketOS 系, ~50KB） |
| 网络 | NetworkManager | **iwd**（内置 DHCP, ~1MB） |
| 音频 | PipeWire | PipeWire（保留） |
| 固件 | linux-firmware 全量 | 仓库精选：ath10k / qca / qcom / postmarketos（gemini 所需，~260MB） |
| swap | zram | zram (lzo-rle) |
| base | ~700MB | ~150MB |

最终 rootfs ≈ **1.2-1.5GB**（含内核模块/固件），镜像文件 **2GB**（首次开机自动扩容至存储剩余空间）。

### 图形界面栈
- **labwc** — wlroots 基座的堆叠式 Wayland 合成器，Openbox 配置语法，CPU/RAM 占用极低
- **seatd** — 轻量 seat/输入设备权限管理（替代 logind）
- **mesa + msm_dri.so** — Adreno 530 GPU 的 DRM/KMS + Gallium 加速
- **xwayland** — 兼容 X11 应用（可选，占用小）
- **tinydm + autologin** — 开机直接进入 gemini 用户的 labwc 会话

---

## 工作流（CI）流程

```
┌─────────────────────────────────────────────────┐
│ GitHub Actions (ubuntu-latest)                  │
├─────────────────────────────────────────────────┤
│ 1. apt 安装: gcc-aarch64 / qemu-user-static     │
│    / e2fsprogs / android-sdk-libsparse-utils    │
│                                                 │
│ 2. 交叉编译仓库内 linux/ (6.3.1 msm8996)        │
│    → Image.gz + jdi/lgd 两个 DTB + 全部模块     │
│    (actions/cache 缓存源码树+对象, 增量编译)     │
│                                                 │
│ 3. 下载 Alpine 官方 minirootfs (aarch64, ~3MB)  │
│                                                 │
│ 4. 创建 2GB ext4 镜像 → 填充 minirootfs         │
│    → chroot (qemu-aarch64-static) 内:           │
│       apk add 基础包 + 图形栈 + iwd/蓝牙        │
│       openrc 服务自启配置                        │
│       内核模块安装 + depmod                      │
│       gemini 用户/密码, ttyGS0 串口, growroot    │
│       firmware/ (LFS) 拷入 /usr/lib/firmware    │
│    → 卸载                                       │
│                                                 │
│ 5. 重新挂载 → mkinitfs (base+ext4+ufs 最小集)   │
│    → mkbootimg (header v0, 参数同 Ubuntu 版)    │
│    → boot-alpine-{jdi,lgd}.img                  │
│                                                 │
│ 6. img2simg → rootfs-alpine.simg                │
│    上传 artifact (tag 推送时同时发 Release)      │
└─────────────────────────────────────────────────┘
```

对应文件：
- 工作流: `.github/workflows/build-alpine.yml`
- rootfs: `scripts/alpine-build-rootfs.sh`
- 打包:   `scripts/alpine-pack-boot.sh`

---

## 本地构建（可选）

在 Ubuntu 24.04 / WSL2 上：

```bash
git clone -b alpine https://github.com/EchoPing07/Ubuntu_For_Xiaomi5_Gemini.git
cd Ubuntu_For_Xiaomi5_Gemini

sudo apt install -y build-essential bc bison flex libncurses-dev libssl-dev \
  libelf-dev gcc-aarch64-linux-gnu qemu-user-static binfmt-support \
  e2fsprogs android-sdk-libsparse-utils python3 curl zstd

# 1. 内核
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=aarch64-linux-gnu-gcc
cp kernel-config/6.3.1-gemini-Ubuntu.config linux/.config
make -C linux -j$(nproc) Image.gz qcom/msm8996-xiaomi-gemini.dtb \
     qcom/msm8996-xiaomi-gemini-lgd-td4322.dtb modules
make -C linux INSTALL_MOD_PATH=$PWD/staging-modules modules_install

# 2. 下载 minirootfs
mkdir -p boot-strap
curl -fSL -o boot-strap/minirootfs.tar.gz \
  https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.1-aarch64.tar.gz

# 3. rootfs + boot
sudo bash scripts/alpine-build-rootfs.sh 3.22.1 labwc 2048
sudo bash scripts/alpine-pack-boot.sh 3.22.1 labwc
img2simg boot/rootfs-alpine.img boot/rootfs-alpine.simg
```

---

## 刷入（与 Ubuntu 版一致）

```bash
# boot 分区 (选对应屏幕)
fastboot flash boot boot-alpine-jdi.img    # JDI 屏
# 或
fastboot flash boot boot-alpine-lgd.img    # LGD 屏

# system 分区 (sparse 镜像)
fastboot flash system rootfs-alpine.simg

# 清空 userdata (首次刷入建议)
fastboot format userdata
```

> 需要已解锁 bootloader，且先刷入适配 gemini 的 TWRP / 分区表（与 Ubuntu 版要求相同）。

---

## 使用

| 项目 | 说明 |
|---|---|
| 默认账号 | `gemini` / 密码 `1234` |
| SSH | 开机自动启动 sshd，wifi 连接后可连 |
| WiFi | `iwctl` 交互式配网（iwd 内置 DHCP）：`station wlan0 connect SSID` |
| 蓝牙 | `bluetoothctl`（bluez） |
| 提权 | `doas`（配置: `/etc/doas.d/doas.conf`） |
| 串口 | USB 数据线 → PC 出现 COM 串口（ttyGS0，115200） |
| 桌面 | 开机自动登录 → labwc（右键 = 应用菜单；`foot` 终端；`fuzzel` 启动器） |
| 音频 | PipeWire（仅 OTG 小尾巴有声音，扬声器/3.5mm 与 Ubuntu 版限制一致） |
| 扩容 | 首次开机 `growroot` 服务自动扩容到存储剩余空间 |

---

## 与 Ubuntu 版的差异点（排障参考）

1. **init 系统**: OpenRC 而非 systemd。服务状态用 `rc-status` / `rc-service <svc> status` 查询。
2. **C 库**: musl。若跑 glibc 闭源二进制需装 `gcompat`。
3. **显示管理**: tinydm 日志在 `~/.local/state/tinydm.log`，labwc 日志在同目录。
4. **固件**: 不使用 Alpine 官方 `linux-firmware-qcom`（其 3.22 版固件为 zstd 压缩，6.3.1 内核未启用 `FW_LOADER_COMPRESS_ZSTD`），直接用仓库 `firmware/`（与 Ubuntu 版同一套、已验证适配）。
5. **resize**: 用 `resize2fs` + OpenRC `growroot`（一次性）替代 systemd `resizefs.service`。

---

## 已知限制（与 Ubuntu 版一致）

- 音频仅 OTG 小尾巴输出
- 触摸三大金刚键不可用
- WiFi 与热点不能同时开启（硬件限制）
- 开机约 1 分钟后才出现 wifi 网卡
