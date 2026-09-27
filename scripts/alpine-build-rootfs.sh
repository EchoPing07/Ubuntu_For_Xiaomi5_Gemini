#!/bin/bash
# =============================================================================
# Alpine Linux rootfs 构建脚本 —— 小米 5 (gemini / msm8996)
# 在 GitHub Actions ubuntu-latest 主机上以 root 运行
#
# 流程: 创建 ext4 镜像 -> 填充官方 minirootfs -> qemu-user chroot 内
#       apk 安装轻量图形栈 (labwc/foot/fuzzel) -> OpenRC 服务配置
#       -> 内核模块 + 仓库固件 -> 清理瘦身
#
# 思路与 Ubuntu 版 (docs/BUILDING.md) 一致, 用户态换为 Alpine
# =============================================================================
set -euo pipefail

ALPINE_VERSION="${1:?usage: alpine-build-rootfs.sh <alpine-version> <session> <rootfs-size-mb>}"
SESSION="${2:?missing session}"
ROOTFS_SIZE_MB="${3:?missing rootfs size}"

REPO="$(pwd)"
WORK="$REPO/work-rootfs"
MNT="$WORK/mnt"
IMG="$REPO/boot/rootfs-alpine.img"
STAGING_MODULES="$REPO/staging-modules"
MINIROOTFS="$REPO/boot-strap/minirootfs.tar.gz"

# 默认账号 (与 Ubuntu 版保持一致: gemini/1234)
DEFAULT_USER="gemini"
DEFAULT_PASS="1234"
HOSTNAME="xiaomi-5"
DEFAULT_UID=1000

log() { echo -e "\n\033[1;32m[ROOTFS]\033[0m $*"; }
# 与主机环境隔离, 避免环境变量泄漏进 chroot
run_in_chroot() {
    sudo chroot "$MNT" /usr/bin/env -i /bin/sh -exc "$*"
}

sudo mkdir -p "$REPO/boot" "$WORK" "$MNT"

cleanup() {
    set +e
    for d in proc dev sys; do
        mountpoint -q "$MNT/$d" && sudo umount -f "$MNT/$d"
    done
    mountpoint -q "$MNT" && sudo umount -f "$MNT"
    mountpoint -q "$MNT" && sudo umount -l -f "$MNT"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1. 创建 ext4 rootfs 镜像并填充 minirootfs
# -----------------------------------------------------------------------------
log "创建 ${ROOTFS_SIZE_MB}MiB ext4 镜像"
rm -f "$IMG"
truncate -s "$((ROOTFS_SIZE_MB))M" "$IMG"
sudo mkfs.ext4 -q -F -L alpine-gemini -I 256 -b 4096 "$IMG"

log "挂载镜像并解压 minirootfs"
sudo mount -o loop "$IMG" "$MNT"
sudo tar -xzf "$MINIROOTFS" -C "$MNT"

# -----------------------------------------------------------------------------
# 2. 挂载伪文件系统, 准备 qemu binfmt
# -----------------------------------------------------------------------------
sudo mount --bind /proc "$MNT/proc"
sudo mount --bind /dev  "$MNT/dev"
sudo mount --bind /sys  "$MNT/sys"

QEMU="/usr/bin/qemu-aarch64-static"
if [ ! -e "$QEMU" ]; then
    echo "ERROR: qemu-aarch64-static 未找到" >&2
    exit 1
fi
sudo cp "$QEMU" "$MNT/usr/bin/"

# DNS: 静态写入 (iwd 不管理 resolv.conf 时使用)
sudo tee "$MNT/etc/resolv.conf" > /dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

log "配置 apk 仓库 (v3.22 main + community)"
sudo tee "$MNT/etc/apk/repositories" > /dev/null <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.22/main
https://dl-cdn.alpinelinux.org/alpine/v3.22/community
EOF

# -----------------------------------------------------------------------------
# 3. 安装基础系统 (musl/busybox/openrc 已在 minirootfs 中)
# -----------------------------------------------------------------------------
log "apk update + 基础软件包"
run_in_chroot apk update
run_in_chroot apk add --no-progress \
    alpine-base alpine-conf \
    linux-pam pam-rundir doas \
    kmod e2fsprogs e2fsprogs-extra dosfstools \
    util-linux-misc findmnt blkid \
    openssh-server openssh-server-common-openrc \
    chrony chrony-openrc tzdata \
    iwd iwd-openrc wpa_supplicant-openrc \
    dbus dbus-openrc \
    eudev eudev-openrc udev-init-scripts-openrc \
    nano htop socat \
    mkinitfs

# -----------------------------------------------------------------------------
# 4. OpenRC 服务配置 (udev 替代 mdev, 供 libinput/libudev 使用)
# -----------------------------------------------------------------------------
log "配置 OpenRC 启动服务"
run_in_chroot "rc-update del mdev sysinit 2>/dev/null || true"
run_in_chroot rc-update add udev sysinit
run_in_chroot rc-update add udev-trigger sysinit
run_in_chroot rc-update add udev-settle sysinit
# devfs/dmesg/hwdrivers 已由 minirootfs 预置, 幂等补齐
run_in_chroot rc-update add devfs sysinit 2>/dev/null || true
run_in_chroot rc-update add dmesg sysinit 2>/dev/null || true
run_in_chroot rc-update add hwdrivers sysinit 2>/dev/null || true

run_in_chroot rc-update add modules boot 2>/dev/null || true
run_in_chroot rc-update add sysctl boot 2>/dev/null || true
run_in_chroot rc-update add hostname boot 2>/dev/null || true
run_in_chroot rc-update add bootmisc boot 2>/dev/null || true
run_in_chroot rc-update add syslog boot 2>/dev/null || true

run_in_chroot rc-update add acpid default 2>/dev/null || true
run_in_chroot rc-update add dbus default
run_in_chroot rc-update add chronyd default
run_in_chroot rc-update add sshd default
run_in_chroot rc-update add iwd default
# seatd/tinydm/bluetooth 包在后续步骤安装, 此处先跳过 (幂等补齐)若无害

run_in_chroot rc-update add mount-ro shutdown 2>/dev/null || true
run_in_chroot rc-update add killprocs shutdown 2>/dev/null || true
run_in_chroot rc-update add savecache shutdown 2>/dev/null || true

# -----------------------------------------------------------------------------
# 5. 内核模块 (staging) + depmod
# -----------------------------------------------------------------------------
log "安装内核模块"
sudo mkdir -p "$MNT/lib/modules"
sudo cp -a "$STAGING_MODULES/lib/modules/." "$MNT/lib/modules/"
KVER="$(basename "$(ls -d "$MNT"/lib/modules/* | head -1)")"
log "内核版本: $KVER"
run_in_chroot "depmod -a $KVER"

# -----------------------------------------------------------------------------
# 6. hostname / 时区
# -----------------------------------------------------------------------------
sudo tee "$MNT/etc/hostname" > /dev/null <<EOF
$HOSTNAME
EOF
sudo tee "$MNT/etc/hosts" > /dev/null <<EOF
127.0.0.1   localhost $HOSTNAME
::1         localhost
EOF
run_in_chroot "ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime"

# -----------------------------------------------------------------------------
# 7. 默认用户 gemini / 1234 (与 Ubuntu 版一致)
# -----------------------------------------------------------------------------
log "创建用户 $DEFAULT_USER (密码 $DEFAULT_PASS)"
run_in_chroot "id -u $DEFAULT_USER >/dev/null 2>&1 || adduser -D -u $DEFAULT_UID -s /bin/ash -G wheel $DEFAULT_USER"
run_in_chroot "echo '$DEFAULT_USER:$DEFAULT_PASS' | chpasswd"
run_in_chroot "echo 'permit persist :wheel' > /etc/doas.d/doas.conf && chmod 600 /etc/doas.d/doas.conf"
# 设备权限组: video(渲染) input(触摸) render(GPU) seat(seatd) audio(音频)
run_in_chroot "for g in video input render seat audio netdev; do addgroup $DEFAULT_USER \$g 2>/dev/null || true; done"

# -----------------------------------------------------------------------------
# 8. 图形栈: labwc + foot + fuzzel + seatd + tinydm 自动登录
# -----------------------------------------------------------------------------
log "安装图形栈"
run_in_chroot apk add --no-progress \
    labwc foot fuzzel \
    seatd seatd-openrc seatd-launch \
    mesa mesa-egl mesa-gbm mesa-dri-gallium \
    font-dejavu \
    tinydm tinydm-openrc autologin \
    pipewire wireplumber

log "配置 tinydm 自动登录 (UID=$DEFAULT_UID)"
sudo tee "$MNT/etc/conf.d/tinydm" > /dev/null <<EOF
AUTOLOGIN_UID=$DEFAULT_UID
EOF
run_in_chroot "tinydm-set-session -f -s /usr/share/wayland-sessions/labwc.desktop"
run_in_chroot rc-update add tinydm default
run_in_chroot rc-update add seatd default

# labwc (libseat/seatd 后端) 需要 XDG_RUNTIME_DIR; tinydm autologin 会话
# 由 pam_rundir 创建 /run/user/$UID, 此处预建目录以保险
sudo mkdir -p "$MNT/var/lib/gemini"
sudo chown "$DEFAULT_UID:$DEFAULT_UID" "$MNT/var/lib/gemini"

log "写入 labwc 用户配置 (触摸友好, 键盘/启动器快捷键)"
sudo mkdir -p "$MNT/home/$DEFAULT_USER/.config/labwc"
sudo tee "$MNT/home/$DEFAULT_USER/.config/labwc/rc.xml" > /dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<labwc_config>
  <core><decorate>yes</decorate></core>
  <theme>
    <name>default</name>
    <cornerRadius>6</cornerRadius>
    <font><name>DejaVu Sans</name><size>10</size></font>
  </theme>
  <keyboard>
    <keybind key="W-Return"><action name="Execute" command="foot"/></keybind>
    <keybind key="W-d"><action name="Execute" command="fuzzel"/></keybind>
    <keybind key="A-Tab"><action name="NextWindow"/></keybind>
  </keyboard>
  <libinput>
    <device>
      <naturalScroll>no</naturalScroll>
      <leftHanded>no</leftHanded>
      <tap>yes</tap>
      <tapButtonMap>lrm</tapButtonMap>
    </device>
  </libinput>
</labwc_config>
EOF

sudo tee "$MNT/home/$DEFAULT_USER/.config/labwc/menu.xml" > /dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu>
  <menu id="root-menu" label="Applications">
    <item label="终端 (foot)"><action name="Execute" command="foot"/></item>
    <item label="启动器 (fuzzel)"><action name="Execute" command="fuzzel"/></item>
    <item label="htop"><action name="Execute" command="foot htop"/></item>
    <item label="iwctl 配网"><action name="Execute" command="foot iwctl"/></item>
    <item label="退出登录"><action name="Exit"/></item>
  </menu>
</openbox_menu>
EOF

sudo tee "$MNT/home/$DEFAULT_USER/.config/labwc/autostart" > /dev/null <<'EOF'
# PipeWire 音频服务栈 (用户会话)
pipewire &
pipewire-pulse &
wireplumber &
EOF

sudo chown -R "$DEFAULT_UID:$DEFAULT_UID" "$MNT/home/$DEFAULT_USER"

# -----------------------------------------------------------------------------
# 9. WiFi (iwd 内置 DHCP + 网络配置) / 蓝牙 (bluez)
# -----------------------------------------------------------------------------
log "配置 iwd (WiFi)"
sudo mkdir -p "$MNT/var/lib/iwd"
sudo tee "$MNT/etc/iwd/main.conf" > /dev/null <<'EOF'
[General]
EnableNetworkConfiguration=true
EOF
run_in_chroot "rc-update del wpa_supplicant default 2>/dev/null || true"
run_in_chroot rc-update add iwd default

log "蓝牙 bluez"
run_in_chroot apk add --no-progress bluez bluez-openrc
run_in_chroot rc-update add bluetooth default

# -----------------------------------------------------------------------------
# 10. zram swap (lzo-rle, 2GB)
# -----------------------------------------------------------------------------
log "配置 zram"
run_in_chroot apk add --no-progress zram-init zram-init-openrc
sudo tee "$MNT/etc/conf.d/zram-init" > /dev/null <<'EOF'
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
size0=2048
algo0=lzo-rle
EOF
run_in_chroot rc-update add zram-init default

# -----------------------------------------------------------------------------
# 11. /etc/fstab (/tmp tmpfs) + 开机自动扩容 ext4
# -----------------------------------------------------------------------------
sudo tee "$MNT/etc/fstab" > /dev/null <<'EOF'
tmpfs   /tmp  tmpfs  rw,nosuid,nodev,mode=1777  0 0
EOF

log "配置开机自动扩容 (growroot)"
sudo tee "$MNT/etc/init.d/growroot" > /dev/null <<'EOF'
#!/sbin/openrc-run
description="在线扩展 ext4 根文件系统到镜像/分区全部可用空间"

depend() {
    after localmount
}

start() {
    local rootdev
    rootdev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    case "$rootdev" in
        /dev/*)
            ebegin "在线扩容根文件系统 ($rootdev)"
            resize2fs "$rootdev"
            eend $?
            ;;
        *)
            ebegin "根文件系统无需扩容"
            eend 0
            ;;
    esac
    # 幂等: 每次开机运行, 无可扩空间时为快速 no-op
}
EOF
sudo chmod +x "$MNT/etc/init.d/growroot"
run_in_chroot rc-update add growroot default

# -----------------------------------------------------------------------------
# 12. ttyGS0 串口控制台 + USB gadget 模块 (与 Ubuntu 版一致)
# -----------------------------------------------------------------------------
log "启用 ttyGS0 串口登录"
sudo tee "$MNT/etc/init.d/serial-getty" > /dev/null <<'EOF'
#!/sbin/openrc-run
description="USB Gadget 串口控制台 (ttyGS0, 115200)"

command="/sbin/getty"
command_args="-L 115200 ttyGS0 xterm-256color"
command_background="yes"
pidfile="/run/serial-getty.pid"

depend() {
    after localmount modules
}
EOF
sudo chmod +x "$MNT/etc/init.d/serial-getty"
run_in_chroot rc-update add serial-getty default

sudo tee -a "$MNT/etc/modules" > /dev/null <<'EOF'
g_serial
EOF

# -----------------------------------------------------------------------------
# 13. SSH 允许密码登录
# -----------------------------------------------------------------------------
log "配置 sshd"
sudo mkdir -p "$MNT/etc/ssh/sshd_config.d"
sudo tee "$MNT/etc/ssh/sshd_config.d/50-gemini.conf" > /dev/null <<'EOF'
PasswordAuthentication yes
PermitRootLogin no
EOF

# -----------------------------------------------------------------------------
# 14. 固件: 仓库 firmware/ (LFS, 已验证适配 6.3.1 内核)
#     注: 不用 Alpine 官方 linux-firmware-qcom (其固件为 zstd 压缩,
#         内核未启用 CONFIG_FW_LOADER_COMPRESS_ZSTD)
# -----------------------------------------------------------------------------
log "拷贝仓库固件 (qcom msm8996/gemini + ath10k + qca BT)"
sudo mkdir -p "$MNT/lib/firmware"
sudo cp -a "$REPO/firmware/." "$MNT/lib/firmware/"

# -----------------------------------------------------------------------------
# 15. 清理瘦身
# -----------------------------------------------------------------------------
log "清理"
run_in_chroot "rm -rf /var/cache/apk/* /tmp/* /var/tmp/* /root/.ash_history 2>/dev/null || true"
sudo rm -f "$MNT/usr/bin/qemu-aarch64-static"

# 构建标记
sudo tee "$MNT/etc/alpine-gemini-release" > /dev/null <<EOF
ALPINE_VERSION=${ALPINE_VERSION}
KERNEL=${KVER}
SESSION=${SESSION}
BUILD_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DEFAULT_USER=${DEFAULT_USER}
EOF

log "同步并卸载"
sync
cleanup
trap - EXIT

log "完成: $IMG"
e2fsck -fn "$IMG" 2>/dev/null | tail -2 || true
