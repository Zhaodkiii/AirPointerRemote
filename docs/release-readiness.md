# AirPointer Remote 首发检查

App Store Connect 记录为 AirPointer Remote - Air Mouse（6836338720），主语言英语（美国）。此前确认首发覆盖 174 个市场，中国大陆未供应。发布前在商店后台复核地区，分别提交 iOS（内嵌独立运行的 Watch App）和 macOS 版本。

## 三端基础操作与后续优先级

| 客户端 | 首发前必须验收 | 下一轮体验改进 |
| --- | --- | --- |
| iPhone | 无 Mac 时看得到安装与权限说明；首次配对、拒绝、权限变更、重新连接、左右键、双击、滚动、拖动，以及退出后台时释放按钮 | 可管理多个 Mac；可选的指针练习区；优化 VoiceOver 下触控板与按住类操作 |
| Apple Watch | 搜索、Mac 端批准或拒绝、授权未开启、另一设备占用、暂停、表冠滚动、退出或熄屏后释放按钮 | 改用可核对配对码的加密认证；提供更稳的连接重试、单手操作及小屏和大字体优化 |
| Mac | **签名且启用沙盒的 Release** 可广播并接收 BLE，用户授权后可在 Finder 和浏览器移动、点击、滚动和拖动；拒绝权限时仍能查看帮助和退出 | 可查看并撤销单台设备；更清楚的手机／手表切换；补多屏、睡眠、锁屏及长期运行测试 |

Watch 现有协议需要 Mac 对每次连接明确批准，和 iPhone 的密钥配对不同。发布资料不可把 iPhone 的端到端加密配对描述成 Watch 也具备。商业化前应优先把 Watch 迁移到带设备身份验证的协议。若仍采用当前方案，务必实测陌生设备被拒绝、并发连接不能接管已批准会话。

## 审核风险和送审条件

- **2.1，核心功能无法测试或无法使用。** 说明三端之间的依赖关系，iPhone 或 Apple Watch 需连接开放蓝牙和辅助功能的 Mac。审核备注应列出实测硬件与系统版本、配对顺序、权限入口和两条控制路径。附实拍视频，展示实际手机及手表与 Mac 配对，再操作真实光标。使用沙盒 Release 验证并录制；本地归档和签名只验证分发结构。Mac 若仍无法发送鼠标事件，暂停 Mac App Store 送审并排查公开 API 的可行性。
- **2.3，商店素材与实际功能不符。** 使用最终英文界面的 iPhone、Watch 和 Mac 截图。准确披露配套 Mac App、蓝牙、权限和系统版本。不要宣称免装 Mac 客户端、全程后台控制或未经实测的延迟。
- **2.4.5 / 2.5.1，Mac 沙盒和公开 API。** 分发包保持 App Sandbox 与 Bluetooth entitlement。Mac 使用 Core Graphics 的公开事件权限 API，逐一验证授权、撤销、系统重启、安装升级和登录后的行为。保留 App 内可用的暂停与退出。
- **5.1.1，权限说明、隐私和支持。** 三端包含隐私清单，公开发布英文隐私政策和支持页，并将有效链接加入 App Store Connect；正式提交前将隐私政策入口放进 App。政策需覆盖蓝牙传输、传感器用途、本地配对记录、撤销方法与联系渠道。按最终代码和 SDK 核实 App Privacy 标签；加入日志上报或分析前重新核对。
- **加密申报。** iPhone 和 Mac 的 BLE 会话使用 Apple CryptoKit。按 App Store Connect 的问卷和首发地区确认出口合规答案。隐私清单与加密问卷是两项独立材料。
- **商业化。** 先决定是付费下载还是免费加一次性 Pro 解锁。付费下载路径简单，适合功能固定的鼠标工具。若在商店版 App 内售卖数字功能，使用 StoreKit，覆盖购买、取消、恢复购买及跨平台权益；商店文案明确付费范围。有明确持续服务价值再考虑订阅。价格和内购需单独确定。
- **5.2，名称和素材权利。** 保留上游 MIT 版权和许可。商店可用名称不代表已核验商标。使用自有品牌素材或确认资产许可，并留存来源。

## 英文审核备注草稿

> AirPointer Remote uses Bluetooth to control the system pointer on a nearby Mac. The macOS app is the receiver, and either the iPhone app or the independent Apple Watch app can act as a controller. No account is required.
>
> Open AirPointer Remote on the Mac and find its menu bar icon. Open Accessibility Settings from that menu and allow pointer control. Turn on Bluetooth on both devices. On iPhone, select the Mac and confirm the matching code on both devices. On Apple Watch, select the Mac and approve the connection on the Mac. Test pointer movement, click, drag, and scrolling. To stop control, use Stop All Control in the Mac menu.

补上实测机型与系统、视频链接和审核联系方式后再提交。隐私政策与支持页需要真实可访问的公开 URL。英文底稿见 [Privacy Policy](privacy-policy-draft.md) 和 [Support](support-draft.md)，发布前补上可用的联系渠道。

Apple 官方参考：[审核指南](https://developer.apple.com/app-store/review/guidelines/) · [完整审核材料](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/) · [隐私清单](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) · [Mac App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) · [加密申报](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
