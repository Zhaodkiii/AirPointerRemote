# AirPointer Remote

用 iPhone 或 Apple Watch 通过蓝牙控制 Mac 的系统鼠标。iPhone 支持触控板、空中鼠标和混合模式，Apple Watch 可以独立连接 Mac。

打开 `AirPointerRemote.xcodeproj`，在 Xcode 中选择下面的 Scheme：

| Scheme | 最低系统 | Bundle ID |
| --- | --- | --- |
| AirPointer Remote iPhone | iOS 17 | `com.daokaihua.airpointerremote` |
| AirPointer Remote Watch | watchOS 11 | `com.daokaihua.airpointerremote.watchkitapp` |
| AirPointer Remote Mac | macOS 14 | `com.daokaihua.airpointerremote` |

先运行 Mac 接收端，允许蓝牙访问，并在「系统设置 → 隐私与安全性 → 辅助功能」中为新 App 授权。然后在 iPhone 或手表上选择 Mac 并完成配对。新 Bundle ID 对应新的 App 安装和权限记录，首次使用需要重新配对。Mac 菜单栏可以暂停、撤销手机配对或退出。紧急停止快捷键为 Control + Option + Command + 句号。

Mac 的 Debug 配置沿用开发版的鼠标控制方式。Release 配置启用了 App Sandbox 和蓝牙设备权限，用于验证 Mac App Store 分发版。发布前要用带签名的 Release 构建在真机上检查蓝牙发现、配对、全系统移动、点击、拖动和滚动。在 Xcode 的 Mac Scheme 中把 Run 的 Build Configuration 切到 Release 就能测试这份配置。

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

1. 核对三个 Target 的 Apple Developer Team，并在开发者账号中注册主 Bundle ID 与 Watch Bundle ID。提交前可在项目级设置里统一修改 `AIRPOINTER_BUNDLE_ID`。
2. 在 App Store Connect 创建 iOS 产品记录，选择主 Bundle ID，再为该记录添加 macOS 平台。
3. 用 iPhone Scheme 选择通用 iOS 设备并归档。Watch App 随 iPhone 构建上传。单独用 Mac Scheme 归档 macOS 构建。
4. 在 Xcode Organizer 验证并上传两个签名归档。用 TestFlight 检查分发版体验，填写 Apple Watch 截图、隐私和支持信息、加密申报及配对说明后送审。

## 官网 Mac 安装包

在项目目录运行：

```bash
./scripts/build-mac-dmg.sh
```

脚本从当前源码构建 Mac Release，打包 Apple silicon 和 Intel 两种架构，并使用团队 `4AN6PV98G7` 的 Developer ID Application 签名。需要 Xcode 和 Python 3。首次运行会通过 PyPI 将 dmgbuild 安装到项目的本地构建目录。默认使用 Xcode 已登录的团队账号公证包内 App，安装镜像输出到 `DerivedData/WebsiteRelease/`，文件名带有 `-app-notarized`。

官网发布时，使用团队已配置的 notarytool 钥匙串凭据为最终 DMG 公证：

```bash
AIRPOINTER_NOTARY_PROFILE=AirPointerNotary ./scripts/build-mac-dmg.sh
```

`AirPointerNotary` 是示例名称。首次可运行 `xcrun notarytool store-credentials AirPointerNotary`，按交互提示配置团队认证。脚本会验证 DMG 的公证票据和包内 App 的签名，并输出带版本号和构建号的安装包路径。用户打开 DMG，将 AirPointer Remote 拖入 Applications，再从 Applications 打开，菜单栏会显示接收端图标。

脚本验证通过后，也将相同的 DMG 更新到 `iPhone/Resources/AirPointer Remote for Mac.dmg`。随后重新构建 iPhone App，即可在 **Choose Your Mac** 页面进入 **Set Up Your Mac**，再点 **Share Mac Installer** 打开系统分享面板。例如，选择 AirDrop 将文件传到 Mac，再手动安装和开启接收端。已安装的 iPhone 版本随下一次构建和安装取得新 DMG。

## 开发检查

运行 `Tests/run-phone-checks.sh` 检查配对协议、姿态换算和鼠标事件生成。系统级鼠标控制需要在物理 Mac 上验证。

首发验收、Apple 审核风险与英文审核备注见 [发布检查](docs/release-readiness.md)。

## 致谢

特别感谢 Umar Afzal 开源 [WatchPointer](https://github.com/umarz317/WatchPointer)。AirPointer Remote 基于 WatchPointer 开发，并在其基础上加入了 iPhone 遥控支持。

本项目保留原作者的版权声明与 [MIT 许可证](LICENSE)，并随三端 App 一起打包。
