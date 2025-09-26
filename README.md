# AI Home 控制平台（iOS）

AI Home 是一个面向智能家居场景的 iOS SwiftUI 应用，当前定位为 MVP：通过 MQTT 与 HTTP 双通道管理和控制家庭终端设备，未来将引入大语言模型与自动化编排，让 AI 成为跨品牌、跨协议的家庭控制中枢。

## 功能亮点
- **统一的设备管理**：支持设备新增、编辑、删除，按控制通道（MQTT/HTTP）自动分类，提供详情页快速执行动作。
- **灵活的控制模型**：通过分组、顺序化的指令集合构建控制面板，支持状态 Topic 与命令 Topic 的灵活拼接。
- **MQTT/HTTP 双通道**：内置 `MQTTManager` 处理 CocoaMQTT 连接、订阅与消息分发，`HTTPClient` 支持携带自定义 Header 的公共网络接口调用。
- **安全配置存储**：使用 SwiftData 持久化设备与全局设置，敏感凭据写入 iOS Keychain，默认初始化公共演示环境。
- **SwiftUI 原生体验**：可扩展的 Tab 架构（设备 + 设置），自适应按钮网格、动画反馈等交互细节。

## 快速开始
1. **环境准备**
   - Xcode 15.4 或以上
   - iOS 17 模拟器或真机
2. **获取代码**
   ```bash
   git clone https://github.com/wonderland-club/ai_home.git
   cd ai_home
   ```
3. **打开工程**
   - 双击 `ai_home.xcodeproj`，等待 Swift Package Manager 自动拉取 `CocoaMQTT` 依赖。
4. **配置默认凭据（可选）**
   - 在真机/模拟器首次运行时，前往“设置”标签页，填写 MQTT Host、端口、用户名，以及 HTTP Base URL。
   - 点击“保存并连接”同步写入 Keychain，并触发自动重连。
5. **运行与调试**
   - 选择目标设备后直接 `⌘R` 启动。
   - 设备列表可实时显示各控制组的动作数量，进入详情页即可触发指令。

## 项目结构
```
ai_home/
├── AddDeviceView.swift        // 新增设备与控制动作的表单
├── DeviceListView.swift       // 设备列表与导航入口
├── DeviceDetailView.swift     // 设备详情，MQTT/HTTP 控制面板
├── SettingsView.swift         // MQTT/HTTP 全局配置与 Keychain 集成
├── MQTTManager.swift          // MQTT 连接、订阅、消息调度
├── MQTTWebSocketTransport.swift // WebSocket 传输支持
├── HTTPClient.swift           // 公网 HTTP 调用封装
├── KeychainHelper.swift       // 凭据读写工具
├── Models.swift               // SwiftData 模型定义
└── RootTabView.swift          // Tab 入口、整体路由
```
更多背景设计请参考 `docs/mvp-home-control.md`。

## 技术栈
- **UI 框架**：SwiftUI
- **数据层**：SwiftData + Keychain
- **网络**：CocoaMQTT、URLSession
- **最低系统**：iOS 17

## 配置说明
- **MQTT**：支持 TCP/TLS 与 WebSocket；可配置 ClientID 前缀、Topic、用户名与密码。
- **HTTP**：支持设置 Base URL、Bearer Token、请求头覆盖；可为设备定义不同的 HTTP 控制指令。
- **默认演示环境**：首启动时会初始化 `mqtt.aimaker.space` 等示例参数，可在设置页覆盖。

## 未来规划
1. **AI 控制中枢**：与大语言模型对接，实现“自然语言 → 自动编排 → 执行”的全流程，支持多轮指令与上下文记忆。
2. **意图识别与自动化**：引入日程、地理围栏、家庭场景触发器，让 AI 按场景自动控制设备。
3. **跨协议适配**：扩展到 Matter、HomeKit、Zigbee 等协议，通过统一抽象层接入更多终端。
4. **多用户协同**：支持家庭成员权限与共享设备集，实现多人协作与审批流程。
5. **可观测性与安全**：提供操作审计、告警订阅与安全隔离策略。

## 贡献与反馈
欢迎通过 Issue 与 Pull Request 参与建设。若需讨论长期路线（AI 控制、硬件生态），可在仓库讨论区发起话题。

