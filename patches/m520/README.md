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
