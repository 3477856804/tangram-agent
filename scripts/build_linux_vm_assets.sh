#!/usr/bin/env bash
# 构建“完整 Linux VM”资产：真内核 + initramfs + Ubuntu 24.04 根盘。
#
# 产物（默认 output/vm_assets）：
#   Image        解压后的 arm64 Linux 内核（QEMU -kernel 直接加载）
#   initrd.gz    自定义 initramfs：挂载 squashfs 根盘后 switch_root 到 /bin/bash
#   root.sqfs    Ubuntu 24.04 base 的 squashfs 根文件系统（只读）
#   manifest.json 版本/大小/SHA256
#
# 依赖：curl、tar、gzip、cpio、mksquashfs（squashfs-tools）、python3。
# 说明：这是“真内核 VM”，不是 proot；Android 端需要另行提供 qemu-system-aarch64
#       可执行文件（见 linux_vm.dart 的解析顺序），桌面端可直接用系统 qemu。
set -euo pipefail

OUT="${1:-output/vm_assets}"
ALPINE_VER="${ALPINE_VER:-3.20}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/alpine}"
UBUNTU_URL="${UBUNTU_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
echo "==> 1/5 下载 Alpine 内核与 initramfs"
curl -fSL --retry 3 "$ALPINE_MIRROR/v$ALPINE_VER/releases/aarch64/netboot/vmlinuz-virt" -o "$WORK/vmlinuz-virt"
curl -fSL --retry 3 "$ALPINE_MIRROR/v$ALPINE_VER/releases/aarch64/netboot/initramfs-virt" -o "$WORK/initramfs-virt"

echo "==> 2/5 从 EFI zboot 中提取未压缩 arm64 Image"
python3 - "$WORK/vmlinuz-virt" "$WORK/Image" <<'PY'
import sys, zlib
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
for p in range(0, len(data) - 8):
    try:
        out = zlib.decompress(data[p:], 16 + zlib.MAX_WBITS)
    except Exception:
        continue
    if out[0x38:0x3c] == b'ARM\x64':
        open(dst, 'wb').write(out)
        print(f'extracted Image at offset {p}, {len(out)} bytes')
        break
else:
    raise SystemExit('failed to extract arm64 Image from vmlinuz-virt')
PY

echo "==> 3/5 下载并解包 Ubuntu 24.04 base"
curl -fSL --retry 3 "$UBUNTU_URL" -o "$WORK/ubuntu-base.tar.gz"
mkdir -p "$WORK/rootfs"
tar -xzf "$WORK/ubuntu-base.tar.gz" -C "$WORK/rootfs"

echo "==> 4/5 构建只读 squashfs 根盘"
mksquashfs "$WORK/rootfs" "$OUT/root.sqfs" -comp gzip -noappend -quiet

echo "==> 5/5 构建自定义 initramfs"
mkdir -p "$WORK/initrd"
( cd "$WORK/initrd" && gunzip -c "$WORK/initramfs-virt" | cpio -id --quiet )
cat > "$WORK/initrd/init" <<'EOF'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sys /sys
/bin/busybox mount -t devtmpfs dev /dev 2>/dev/null
/sbin/modprobe virtio_blk 2>/dev/null
/bin/busybox mkdir -p /mnt
/bin/busybox mount -t squashfs -o ro /dev/vda /mnt
if [ ! -x /mnt/bin/bash ]; then
  echo "TGA-VM: root mount failed"
  exec /bin/busybox sh
fi
exec /bin/busybox switch_root /mnt /bin/bash
EOF
chmod +x "$WORK/initrd/init"
( cd "$WORK/initrd" && find . | cpio -o -H newc --quiet | gzip -1 ) > "$OUT/initrd.gz"
cp "$WORK/Image" "$OUT/Image"

python3 - "$OUT" <<'PY'
import hashlib, json, os, sys
out = sys.argv[1]
files = {}
for name in ('Image', 'initrd.gz', 'root.sqfs'):
    path = os.path.join(out, name)
    data = open(path, 'rb').read()
    files[name] = {
        'bytes': len(data),
        'sha256': hashlib.sha256(data).hexdigest(),
    }
manifest = {
    'kind': 'tga-linux-vm',
    'kernel': 'Linux 6.6.134-0-virt (Alpine virt)',
    'distro': 'Ubuntu 24.04.5 LTS (base)',
    'arch': 'aarch64',
    'files': files,
}
open(os.path.join(out, 'manifest.json'), 'w').write(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
PY

echo "完成：$OUT"
