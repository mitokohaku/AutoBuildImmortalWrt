#!/usr/bin/env python3
"""就地修补 ImageBuilder 预置 kernel 映像里的设备树。

ImmortalWrt 官方的 M520 DTS 只开了 &usb3_0/&usb3_1，没开 hs_phy_0/ss_phy_0/
hs_phy_1/ss_phy_1。kernel 6.6 的 qcom-ipq8064.dtsi 里这四个节点默认 disabled，
dwc3 声明 phys=<&hs_phy_0>,<&ss_phy_0> 拿不到 phy 就一直 EPROBE_DEFER，
USB 主控器不注册 → lsusb 报 libusb -99 → LTE 模块认不出来。

为什么改这个文件而不是 image-<dts>.dtb:
  ipq806x 的 ImageBuilder 直接附带组装好的 <profile>-uImage，KDIR 里没有 zImage，
  所以 "KERNEL = kernel-bin | append-dtb | uImage none" 这条管线根本不会执行，
  改 image-*.dtb 不会进最终固件(实测验证过)。

为什么不从源码编译:
  kmod 与内核 vermagic 绑死。只换 DTB 不动内核二进制，官方 kmod 源就依然可用。

uImage 布局: 64 字节头 + (zImage + 追加的 DTB)，之后 pad 到 KERNEL_SIZE。
补丁后的 DTB 会被 dtc -S 填充到与原来完全相同的字节数，因此 ih_size 不变，
只需要重算 ih_dcrc 和 ih_hcrc。
"""
import struct, subprocess, sys, zlib, tempfile, os, shutil

UIMAGE_MAGIC = 0x27051956
FDT_MAGIC = b"\xd0\x0d\xfe\xed"
PHY_NODES = [
    "/soc/phy@100f8800",   # hs_phy_0
    "/soc/phy@100f8830",   # ss_phy_0
    "/soc/phy@110f8800",   # hs_phy_1
    "/soc/phy@110f8830",   # ss_phy_1
]

def run(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"命令失败: {' '.join(a)}\n{r.stderr.strip()}")
    return r.stdout.strip()

def main(path):
    buf = bytearray(open(path, "rb").read())
    magic, hcrc, tm, size, load, ep, dcrc, os_, arch, typ, comp = \
        struct.unpack(">IIIIIIIBBBB", buf[:32])
    if magic != UIMAGE_MAGIC:
        sys.exit(f"不是 uImage: magic={magic:#x}")
    name = buf[32:64].split(b"\0")[0].decode(errors="replace")
    print(f"uImage: name={name!r} data={size} load={load:#x} ep={ep:#x}")

    data = buf[64:64 + size]
    if zlib.crc32(data) != dcrc:
        sys.exit("原始 data CRC 就对不上，映像可能已损坏")

    # 追加的 DTB 在 zImage 之后，取最后一个合理大小的 FDT
    off, dtb_len = None, None
    i = 0
    while True:
        i = data.find(FDT_MAGIC, i)
        if i < 0:
            break
        n = struct.unpack(">I", data[i + 4:i + 8])[0]
        if 4096 < n < 512 * 1024 and i + n <= len(data):
            off, dtb_len = i, n
        i += 4
    if off is None:
        sys.exit("在 kernel 数据里找不到追加的 DTB")
    print(f"追加的 DTB: 位移 {off:#x} 大小 {dtb_len}")

    tmp = tempfile.mkdtemp()
    try:
        src = os.path.join(tmp, "in.dtb")
        dst = os.path.join(tmp, "out.dtb")
        open(src, "wb").write(data[off:off + dtb_len])

        for n in PHY_NODES:
            before = run("fdtget", src, n, "status")
            run("fdtput", "-t", "s", src, n, "status", "okay")
            print(f"  {n}: {before} -> okay")

        # -S 填充回原始字节数，保证 ih_size 不变，可以就地替换
        run("dtc", "-I", "dtb", "-O", "dtb", "-S", str(dtb_len), "-o", dst, src)
        new = open(dst, "rb").read()
        if len(new) != dtb_len:
            sys.exit(f"补丁后大小 {len(new)} != 原始 {dtb_len}，无法就地替换")

        for n in PHY_NODES + ["/soc/usb@100f8800", "/soc/usb@110f8800"]:
            if run("fdtget", dst, n, "status") != "okay":
                sys.exit(f"{n} 没能置为 okay")

        data[off:off + dtb_len] = new
    finally:
        shutil.rmtree(tmp)

    # data 变了 -> 重算 dcrc，再以 hcrc 归零的头重算 hcrc
    new_dcrc = zlib.crc32(bytes(data))
    struct.pack_into(">I", buf, 24, new_dcrc)
    struct.pack_into(">I", buf, 4, 0)
    struct.pack_into(">I", buf, 4, zlib.crc32(bytes(buf[:64])))
    buf[64:64 + size] = data

    open(path, "wb").write(buf)
    print(f"✅ 已就地修补 {path} (dcrc {dcrc:#x} -> {new_dcrc:#x})")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("用法: patch-m520-uimage.py <ruijie_rg-mtfi-m520-uImage>")
    main(sys.argv[1])
