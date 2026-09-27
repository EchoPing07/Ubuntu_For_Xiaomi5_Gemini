#!/bin/bash
# =============================================================================
# boot 镜像打包脚本 —— 小米 5 (gemini / msm8996) Alpine Linux
# 在 GitHub Actions 主机上以 root 运行 (rootfs 构建完成后)
#
# 流程: 生成最小 initramfs (mkinitfs, ufs+ext4 最小特性集)
#       -> Image.gz + DTB 拼接 -> mkbootimg 打包 (jdi / lgd 两块屏幕)
# =============================================================================
set -euo pipefail

ALPINE_VERSION="${1:?usage: alpine-pack-boot.sh <alpine-version> <session>}"
SESSION="${2:?missing session}"

REPO="$(pwd)"
WORK="$REPO/work-rootfs"
MNT="$WORK/mnt"
IMG="$REPO/boot/rootfs-alpine.img"
BOOT="$REPO/boot"
STAGING_MODULES="$REPO/staging-modules"
# 内核版本从 staging 模块目录动态推导, 避免硬编码
KVER="$(basename "$(ls -d "$STAGING_MODULES"/lib/modules/* | head -1)")"

log() { echo -e "\n\033[1;35m[BOOT]\033[0m $*"; }

cleanup() {
    set +e
    if mountpoint -q "$MNT/proc"; then sudo umount -f "$MNT/proc"; fi
    if mountpoint -q "$MNT/dev";  then sudo umount -f "$MNT/dev";  fi
    if mountpoint -q "$MNT/sys";  then sudo umount -f "$MNT/sys";  fi
    if mountpoint -q "$MNT";      then sudo umount -f "$MNT"; fi
    if mountpoint -q "$MNT";      then sudo umount -l -f "$MNT"; fi
}
trap cleanup EXIT

sudo mkdir -p "$BOOT"

# -----------------------------------------------------------------------------
# 1. 挂载 rootfs, 获取 UUID
# -----------------------------------------------------------------------------
log "挂载 rootfs 并读取 UUID"
sudo mount -o loop "$IMG" "$MNT"
ROOT_UUID="$(sudo blkid -s UUID -o value "$IMG")"
if [ -z "$ROOT_UUID" ]; then
    echo "ERROR: 无法读取 rootfs UUID" >&2
    exit 1
fi
log "ROOT_UUID=$ROOT_UUID"

# -----------------------------------------------------------------------------
# 2. 生成最小 initramfs (mkinitfs, 使用 rootfs 内的配置)
# -----------------------------------------------------------------------------
log "生成最小 initramfs (mkinitfs, features: base ext4 ufs, 内核 $KVER)"
# chroot 内执行 mkinitfs; qemu-user-static 已由 rootfs 阶段准备 (仍保留)
QEMU="/usr/bin/qemu-aarch64-static"
[ -e "$QEMU" ] && sudo cp "$QEMU" "$MNT/usr/bin/"

sudo mount --bind /proc "$MNT/proc"
sudo mount --bind /dev  "$MNT/dev"
sudo mount --bind /sys  "$MNT/sys"

# mkinitfs 在 chroot 内运行 (需 qemu-aarch64-static + apk 数据库), 指定特性集
echo "features=\"base ext4 ufs\"" | sudo chroot "$MNT" sh -c 'mkdir -p /etc/mkinitfs && cat > /etc/mkinitfs/mkinitfs.conf'
sudo chroot "$MNT" mkinitfs -F "base ext4 ufs" -o /tmp/initramfs-alpine "$KVER" \
    || { echo "ERROR: mkinitfs 失败" >&2; exit 1; }

sudo cp "$MNT/tmp/initramfs-alpine" "$BOOT/initrd.img"
sudo chown "$(id -u):$(id -g)" "$BOOT/initrd.img"
ls -la "$BOOT/initrd.img"

# -----------------------------------------------------------------------------
# 3. 拼接 kernel + dtb
# -----------------------------------------------------------------------------
log "拼接 Image.gz + DTB"
cp "$REPO/linux/arch/arm64/boot/Image.gz" "$BOOT/Image.gz"
cp "$REPO/linux/arch/arm64/boot/dts/qcom/msm8996-xiaomi-gemini.dtb" "$BOOT/jdi.dtb"
cp "$REPO/linux/arch/arm64/boot/dts/qcom/msm8996-xiaomi-gemini-lgd-td4322.dtb" "$BOOT/lgd.dtb"

cat "$BOOT/Image.gz" "$BOOT/jdi.dtb" > "$BOOT/kernel-dtb-jdi"
cat "$BOOT/Image.gz" "$BOOT/lgd.dtb" > "$BOOT/kernel-dtb-lgd"

# -----------------------------------------------------------------------------
# 4. mkbootimg 打包 (header v0, 参数与 Ubuntu 版完全一致)
# -----------------------------------------------------------------------------
log "打包 boot.img (mkbootimg v0, 4096 pagesize)"
cd "$BOOT"

for variant in jdi lgd; do
    python3 "$REPO/boot/mkbootimg/mkbootimg.py" \
        --header_version 0 \
        --base 0x80000000 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x01000000 \
        --tags_offset 0x00000100 \
        --pagesize 4096 \
        --second_offset 0x00f00000 \
        --ramdisk "$BOOT/initrd.img" \
        --cmdline "console=tty0 root=UUID=$ROOT_UUID rw loglevel=3" \
        --kernel "$BOOT/kernel-dtb-$variant" \
        --output "$BOOT/boot-alpine-$variant.img"
    log "生成 boot-alpine-$variant.img"
done

# -----------------------------------------------------------------------------
# 5. 清理 rootfs 内的临时文件并卸载
# -----------------------------------------------------------------------------
log "卸载 rootfs"
sudo chroot "$MNT" sh -c 'rm -f /tmp/initramfs-alpine' 2>/dev/null || sudo rm -f "$MNT/tmp/initramfs-alpine" || true
sudo rm -f "$MNT/usr/bin/qemu-aarch64-static"
sync
sudo umount "$MNT/proc" "$MNT/dev" "$MNT/sys" 2>/dev/null || true
sudo umount "$MNT" || sudo umount -l "$MNT"
trap - EXIT

log "完成:"
ls -la "$BOOT"/boot-alpine-*.img
