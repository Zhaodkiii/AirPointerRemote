# 构建、使用与发布

打开 `GlideCueRemote.xcodeproj`，在 Xcode 中选择下面的 Scheme：

| Scheme | 最低系统 | Bundle ID |
| --- | --- | --- |
| GlideCue Remote iPhone | iOS 18 | `cn.zhaodk.glidecue` |
| GlideCue Remote Watch | watchOS 11 | `cn.zhaodk.glidecue.watchkitapp` |
| GlideCue Remote Mac | macOS 14 | `cn.zhaodk.glidecue` |
| GlideCue Remote Mac Direct | macOS 14 | `cn.zhaodk.glidecue.direct` |

先运行 Mac 接收端，允许蓝牙访问，并在「系统设置 → 隐私与安全性 → 辅助功能」中为新 App 授权。然后在 iPhone 或手表上选择 Mac 并完成配对。新 Bundle ID 对应新的 App 安装和权限记录，首次使用需要重新配对。Mac 菜单栏可以暂停、撤销手机配对或退出。紧急停止快捷键为 Control + Option + Command + 句号。

Mac 的 Debug 配置沿用开发版的鼠标控制方式。Release 配置启用了 App Sandbox 和蓝牙设备权限，用于验证 Mac App Store 分发版。发布前要用带签名的 Release 构建在真机上检查蓝牙发现、配对、全系统移动、点击、拖动和滚动。在 Xcode 的 Mac Scheme 中把 Run 的 Build Configuration 切到 Release 就能测试这份配置。

## iPhone 直连系统屏幕共享

在 iPhone 首页选择「内置屏幕共享」，可通过局域网发现或输入 VNC 地址连接 Mac。使用方法、两种认证、构建与真机验收见[系统远程桌面](system-desktop.md)。

## 项目目录

| 目录 | 内容 |
| --- | --- |
| `iPhone/` | `App` 应用入口和首页、`Connection` 配对和连接、`Remote` 指针控制、`LinkedScreen` 屏幕共享、`Setup` 安装引导 |
| `Mac/` | `App` 接收端入口、`Connection` 设备连接、`Input` 指针和显示器坐标、`Interface` 菜单栏和浮层、`LinkedScreen` 屏幕采集和编码 |
| `Watch/` | `Sources` 手表遥控界面和连接逻辑 |
| `Shared/` | iPhone 与 Mac 共用的配对协议和屏幕共享传输 |
| 各平台的 `Resources/` | 图标、隐私清单和本地化。iPhone 额外包含安装动画和脚本生成的 Mac 安装包 |
| `Config/` | Xcode 使用的 Info.plist 配置 |
| `Tests/`、`scripts/` | 协议与图传检查、Mac 安装包构建 |
| `docs/`、`Game/` | 项目文档与演示素材、独立网页游戏 |

## App Store 分发

1. 在 Apple Developer 注册 `cn.zhaodk.glidecue`，并在 App Store Connect 创建以英语（美国）为主语言的 iOS 记录。
2. 用 GlideCue Remote iPhone Scheme 选择通用 iOS 设备并归档。此 Scheme 的安装包仅包含 iPhone App。
3. 用 Xcode Organizer 验证并上传签名归档。在 TestFlight 验证后填写商店截图、隐私和支持信息、加密申报及配对说明。

## 合盖桌面

从「应用程序」打开 **GlideCue Remote Direct**。首次打开会显示 **Closed-Lid Desktop** 设置，之后可从 Mac 菜单栏重新打开。保持机盖打开，打开功能开关，允许屏幕录制与鼠标控制，在 **Closed-Lid Power** 项点击 **Set Up** 并按系统提示允许后台服务。直装版使用独立 Bundle ID，首次配对需要重新确认。

在已配对的 iPhone 上点首页 **Share** 或 **Linked Screen → Start Sharing**。看到 Lid Desktop 和「可以合上 Mac 屏幕了」后再合盖。开盖会恢复内屏亮度，手机继续显示原来的虚拟桌面。想显示内屏时，可在手机的 Linked Screen 选择 **Choose a Display on the Mac**。退出共享后，Mac 恢复原睡眠设置。

此前安装过普通接收端或独立的 Lid Desktop 工具时，先从菜单栏结束这些程序，再打开直装版。移除直装版前，可在合盖桌面设置中结束共享并点 **Remove Power Helper**。首次授权、实际合盖、低电量与崩溃恢复需要用真机确认。内屏亮度与虚拟显示器使用 macOS 私有接口，升级 macOS 后要重新验证。

## 官网 Mac 安装包

在项目目录运行：

```bash
./scripts/build-mac-dmg.sh
```

脚本从当前源码构建标准版 Mac Release 并更新 iPhone 内置安装包。直接执行 `./scripts/dmg-layout.py` 也会调用同一打包流程。脚本打包 Apple silicon 和 Intel 两种架构，并使用团队 `4AN6PV98G7` 的 Developer ID Application 签名。需要 Xcode 和 Python 3。首次运行会通过 PyPI 将 dmgbuild 安装到项目的本地构建目录。默认使用 Xcode 已登录的团队账号公证包内 App，安装镜像输出到 `DerivedData/WebsiteRelease/`，文件名带有 `-app-notarized`。

官网发布时，使用团队已配置的 notarytool 钥匙串凭据为最终 DMG 公证：

```bash
AIRPOINTER_NOTARY_PROFILE=AirPointerNotary ./scripts/build-mac-dmg.sh --direct
```

`AirPointerNotary` 是示例名称。首次可运行 `xcrun notarytool store-credentials AirPointerNotary`，按交互提示配置团队认证。脚本会验证 DMG 的公证票据和包内 App 的签名，并输出带版本号和构建号的安装包路径。用户打开 DMG，将 GlideCue Remote 拖入 Applications，再从 Applications 打开，菜单栏会显示接收端图标。

运行 `./scripts/build-mac-dmg.sh --standard` 可构建普通 Mac 版并更新 `iPhone/Resources/GlideCue Remote for Mac.dmg`。随后重新构建 iPhone App，用户可在 **Choose Your Mac → Set Up Your Mac → Share Mac Installer** 找到普通版安装包。使用 `--direct` 生成官网直装版独立的 `-Direct` DMG。

## 开发检查

运行 `Tests/run-phone-checks.sh` 检查配对协议、姿态换算和鼠标事件生成。系统级鼠标控制需要在物理 Mac 上验证。

首发验收、Apple 审核风险与英文审核备注见 [发布检查](release-readiness.md)。
