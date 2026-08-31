# RG-MTFi-M520 源码补丁

用于 `.github/workflows/build-m520-source.yml`，在 ImmortalWrt 源码树根目录用
`git apply` 套用。ImageBuilder 用不上这些补丁——DTB 烧在预编译内核里，改不了。

## 001-ipq806x-m520-enable-usb-phys.patch

**症状**：`lsusb` 报 `unable to initialize libusb: -99`，LTE 模块认不出来。

`-99` 是 `LIBUSB_ERROR_OTHER`，libusb 在 `libusb_init` 找不到 usbfs 根目录时返回。
也就是 `/dev/bus/usb` 不存在。注意这不等于"没插设备"——就算一个 USB 设备都没接，
只要 dwc3 控制器 probe 成功，root hub 也会生成 `/dev/bus/usb/001/001`。所以它说明
**USB 主控器压根没起来**。

原因：kernel 6.6 的 `qcom-ipq8064.dtsi` 里 `hs_phy_0` `ss_phy_0` `hs_phy_1` `ss_phy_1`
默认都是 `status = "disabled"`，而 `dwc3_0` 声明了 `phys = <&hs_phy_0>, <&ss_phy_0>`。
ImmortalWrt 的 M520 DTS 只写了 `&usb3_0` 和 `&usb3_1` 的 okay，四个 PHY 一个没开，
dwc3 拿不到 phy 就一直 `EPROBE_DEFER`。

参照物：in-tree 的 `qcom-ipq8064-rb3011.dts` 是 `&hs_phy_1` `&ss_phy_1` `&usb3_1` 三个都开。

aiamadeus/lede 的 ipq806x 分支没这问题，是因为它跑 kernel 5.4，那一版 ipq806x 的
USB PHY 绑定方式不同，开父节点就够了。

## 002-ipq806x-m520-add-tca9539-gpio-expander.patch

**症状**：SYS 灯不亮；GPIO 扩展器的脚一根都摸不到。

M520 的 DTS 在 gsbi2 的 i2c 上声明了 `ti,tca9539`(地址 0x74) 并作为 `gpio_ext`
gpio-controller，`gpio-leds` 的 SYS 灯挂在 `<&gpio_ext 15>`。但 ImmortalWrt 的
`DEVICE_PACKAGES` 没带 `kmod-gpio-pca953x`，target 的 `config-6.6` 里也没有内建
`CONFIG_GPIO_PCA953X` → 扩展器不 probe → 引用它的 gpio-leds 一直 defer。

装上后 dmesg 会看到：

    pca953x 0-0074: supply vcc not found, using dummy regulator
    pca953x 0-0074: using no AI

这两条是正常的(没在 DTS 里给 vcc regulator，以及该型号不用 auto-increment)。

---

## 更好的做法: 不编源码，只换设备树

上面两个补丁是给源码编译用的，但源码编译有个硬伤: **kmod 与内核 vermagic 绑死**。
自编内核是 6.6.151，官方 24.10.6 仓库是 6.6.133，连版本号都不一样，
`opkg install kmod-usb-audio` 只会得到 `Unknown package`。

而 DTB 只是接在 zImage 后面的一块独立 blob(`KERNEL = kernel-bin | append-dtb`)，
vermagic 是从内核 `.config` 算的，跟 DTB 无关。所以**只换 DTB 不动内核二进制**，
官方 kmod 源就依然可用 —— 见 `scripts/patch-m520-uimage.py`，
已接进 `build-ruijie-m520.yml`。

踩过的坑: 改 KDIR 下的 `image-qcom-ipq8064-rg-mtfi-m520.dtb` **无效**。
ipq806x 的 ImageBuilder 直接附带组装好的 `ruijie_rg-mtfi-m520-uImage`
(4096k，DTB 已 append 进去)，KDIR 里连 zImage 都没有，
`kernel-bin | append-dtb | uImage none` 这条管线根本不会执行。
实测: 挂载覆盖 image-*.dtb 后产出的固件里，DTB 仍是官方原版(30427 字节，逐字节相同)。
必须改 uImage 内部那段 DTB，并重算 ih_dcrc / ih_hcrc。

验证结果(本地实测):
- 补丁前后 uImage 大小都是 4194304，**zImage 区间零字节差异**
- 仅 8 个头部字节(hcrc/dcrc)与 DTB 区间变化
- 两个 CRC 重算后校验通过
- 从产出的 factory.bin 里挖回 DTB，四个 phy 均为 okay

## 全部 disabled 节点的排查

官方 DTB 里共 24 个 `status = "disabled"` 的节点，逐个核对后只有四个 USB PHY 是错的:

| 节点 | 判断 |
|---|---|
| `phy@{100f8800,100f8830,110f8800,110f8830}` | ❌ 该开，本补丁修的就是它们 |
| `ethernet@37000000` / `37600000` | ✅ gmac0/gmac3 未使用，本机走 gmac1+gmac2 |
| `nand-controller@1ac00000` | ✅ 本机是 eMMC + SPI NOR，无 NAND |
| `lpass@28100000` | ✅ 板上无音频 codec |
| `gsbi@{12440000,16500000,16600000}` 及子节点 | ✅ 未接器件 |
| `gsbi@1a200000/i2c@1a280000` | ✅ 同地址的 spi@1a280000 是开的(SPI NOR) |
| `gsbi@12480000/serial@12490000` | ✅ gsbi2 走 I2C，UART 未用 |
| `idle-states/spc` | ✅ ipq806x errata，本就该关 |
| `amba/mmc@12180000` (sdcc3) | ⚠️ 板上有 SD 卡槽才需要开 |
| `pci@1b900000` (pcie2) | ⚠️ 有第三个插槽才需要开 |

**mSATA 不需要动**: `sata` / `sata_phy` 从来就是开的，不在 disabled 清单里。
dmesg 里的 `ata1: SATA link down` 意思是控制器已就绪但没插盘，不是驱动缺失。
