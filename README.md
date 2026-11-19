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

## App Store 分发

1. 核对三个 Target 的 Apple Developer Team，并在开发者账号中注册主 Bundle ID 与 Watch Bundle ID。提交前可在项目级设置里统一修改 `AIRPOINTER_BUNDLE_ID`。
2. 在 App Store Connect 创建 iOS 产品记录，选择主 Bundle ID，再为该记录添加 macOS 平台。
3. 用 iPhone Scheme 选择通用 iOS 设备并归档。Watch App 随 iPhone 构建上传。单独用 Mac Scheme 归档 macOS 构建。
4. 在 Xcode Organizer 验证并上传两个签名归档。用 TestFlight 检查分发版体验，填写 Apple Watch 截图、隐私和支持信息、加密申报及配对说明后送审。

## 开发检查

运行 `Tests/run-phone-checks.sh` 检查配对协议、姿态换算和鼠标事件生成。系统级鼠标控制需要在物理 Mac 上验证。

首发验收、Apple 审核风险与英文审核备注见 [发布检查](docs/release-readiness.md)。

## 致谢

特别感谢 Umar Afzal 开源 [WatchPointer](https://github.com/umarz317/WatchPointer)。AirPointer Remote 基于 WatchPointer 开发，并在其基础上加入了 iPhone 遥控支持。

本项目保留原作者的版权声明与 [MIT 许可证](LICENSE)，并随三端 App 一起打包。
