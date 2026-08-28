#!/bin/bash
source shell/custom-packages.sh
source shell/switch_repository.sh
# 该文件实际为imagebuilder容器内的build.sh

#echo "✅ 你选择了第三方软件包：$CUSTOM_PACKAGES"

# ========= 探测 ImageBuilder 的目标架构 =========
# 本仓库原本只服务 aarch64 机型 但 mt7621(mipsel) bcm53xx(armv7) ipq806x(armv7)
# 这些平台的第三方 ipk 架构与 aarch64 不符 必须区别对待
IB_ARCH=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' .config)
[ -n "$IB_ARCH" ] || IB_ARCH=$(make -s val.ARCH_PACKAGES 2>/dev/null)
echo "🎯 ImageBuilder 目标架构: ${IB_ARCH:-unknown}"

# 第三方 store 仓库只提供 arm64 与 x86 两种目录
case "$IB_ARCH" in
    aarch64_*) STORE_ARCH="arm64" ;;
    x86_64)    STORE_ARCH="x86" ;;
    *)         STORE_ARCH="" ;;
esac

# 允许保留的 ipk 架构白名单(aarch64 两种子架构 ABI 互通 保持原有行为)
case "$IB_ARCH" in
    aarch64_*) ALLOWED_ARCHES="aarch64_generic aarch64_cortex-a53" ;;
    *)         ALLOWED_ARCHES="$IB_ARCH" ;;
esac

mkdir -p /home/build/immortalwrt/extra-packages
if [ -n "$STORE_ARCH" ]; then
    # 下载 run 文件仓库
    echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
    git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo
    # 拷贝 run/$STORE_ARCH 下所有 run 文件和ipk文件 到 extra-packages 目录
    cp -r /tmp/store-run-repo/run/$STORE_ARCH/* /home/build/immortalwrt/extra-packages/
    echo "✅ Run files copied to extra-packages:"
    ls -lh /home/build/immortalwrt/extra-packages/*.run
else
    echo "⚪️ $IB_ARCH 没有对应的第三方 store 目录 仅使用 immortalwrt 官方源"
fi

# 解压并拷贝ipk到packages目录
sh shell/prepare-packages.sh

# 剔除与目标架构不符的 ipk 否则 opkg 解析依赖时会直接失败
for ipk in /home/build/immortalwrt/packages/*.ipk; do
    [ -e "$ipk" ] || continue
    ipk_name=$(basename "$ipk")
    # 架构名本身含下划线(如 aarch64_cortex-a53) 只能按后缀匹配 不能按下划线切分
    keep=0
    # 与架构无关的包一律保留 含 luci-app-run_1.0.0_all-r9.ipk 这类非标准命名
    case "$ipk_name" in
        *_all.ipk|*_all-*.ipk|*_noarch.ipk|*_noarch-*.ipk) keep=1 ;;
    esac
    for a in $ALLOWED_ARCHES; do
        [ "$keep" -eq 1 ] && break
        case "$ipk_name" in
            *_${a}.ipk) keep=1; break ;;
        esac
    done
    if [ "$keep" -eq 0 ]; then
        echo "🚫 架构不符 移除 $ipk_name"
        rm -f "$ipk"
    fi
done
ls -lah /home/build/immortalwrt/packages/

# 添加架构优先级信息
if [ -n "${IB_ARCH}" ]; then
    case "$IB_ARCH" in
        aarch64_*)
            sed -i '1i\
arch aarch64_generic 10\n\
arch aarch64_cortex-a53 15' repositories.conf
            ;;
        *)
            sed -i "1i arch $IB_ARCH 10" repositories.conf
            ;;
    esac
fi



# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"

echo "Include Docker: $INCLUDE_DOCKER"
echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入pppoe变量————>pppoe-settings文件
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."


# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl luci luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
#24.10.0
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"


# 第三方软件包 合并
# ======== shell/custom-packages.sh =======
if [ "$PROFILE" = "glinet_gl-axt1800" ] || [ "$PROFILE" = "glinet_gl-ax1800" ]; then
    # 这2款 暂时不支持第三方插件的集成 snapshot版本太高 opkg换成apk包管理器 6.12内核 
    echo "Model:$PROFILE not support third-parted packages"
    PACKAGES="$PACKAGES -luci-i18n-diskman-zh-cn luci-i18n-homeproxy-zh-cn"
else
    echo "Other Model:$PROFILE"
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    case "$IB_ARCH" in
        aarch64_*)                  CORE_ARCH="arm64" ;;
        x86_64)                     CORE_ARCH="amd64" ;;
        arm_cortex-a15*|arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*neon*) CORE_ARCH="armv7" ;;
        arm_*)                      CORE_ARCH="armv5" ;;
        mipsel_*)                   CORE_ARCH="mipsle-softfloat" ;;
        mips_*)                     CORE_ARCH="mips-softfloat" ;;
        *)                          CORE_ARCH="arm64" ;;
    esac
    echo "OpenClash core arch: $CORE_ARCH"
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$CORE_ARCH.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi


# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
