import Foundation
import SwiftData

// MARK: - 数据结构定义

/// AI规划的动作结果
struct PlannedAction: Codable {
    let topic: String
    let payload: String
    let confidence: Double
    let explanation: String
}

/// 全局AI规划结果
struct GlobalPlannedResult {
    let device: Device
    let action: PlannedAction
}

/// 设备信息（用于AI分析）
struct DeviceInfo: Codable {
    let name: String
    let controlTopic: String
    let commands: [CommandInfo]
}

/// 命令信息（用于AI分析）
struct CommandInfo: Codable {
    let label: String
    let topic: String
    let payload: String
    let expectedState: String
}

/// 豆包Ark API 请求/响应数据结构
struct ArkImageURL: Codable { 
    let url: String 
}

struct ArkContentPart: Codable {
    let type: String // "image_url" | "text"
    let text: String?
    let image_url: ArkImageURL?
}

struct ArkMessage: Codable {
    let role: String // "system" | "user" | "assistant"
    let content: [ArkContentPart]
}

struct ArkChatRequest: Codable {
    let model: String
    let messages: [ArkMessage]
    let temperature: Double?
    let max_tokens: Int?
}

struct ArkChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable { 
            let role: String?
            let content: String? 
        }
        let message: Message
        let finish_reason: String?
    }
    let choices: [Choice]
    let usage: Usage?
    
    struct Usage: Codable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
}

// MARK: - AI规划器实现

// MARK: - 全局AI规划器

/// 全局豆包Ark AI规划器（支持多设备）
final class GlobalArkAIPlanner {
    private let endpoint: URL
    private let apiKey: String
    private let modelName: String
    
    init(endpoint: URL, apiKey: String, modelName: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelName = modelName
    }
    
    /// 根据用户输入和所有设备信息规划全局MQTT动作
    func planGlobal(userInput: String, devices: [Device]) async throws -> GlobalPlannedResult {
        guard !devices.isEmpty else {
            throw AIError.noMQTTConfig
        }
        
        // 构建全局系统提示词
        let systemPrompt = buildGlobalSystemPrompt()
        
        // 构建所有设备的上下文
        let devicesContext = buildDevicesContext(devices: devices)
        
        // 构建用户消息
        let userMessage = buildGlobalUserMessage(userInput: userInput, devicesContext: devicesContext)
        
        // 构建请求
        let messages = [
            ArkMessage(role: "system", content: [
                ArkContentPart(type: "text", text: systemPrompt, image_url: nil)
            ]),
            ArkMessage(role: "user", content: [
                ArkContentPart(type: "text", text: userMessage, image_url: nil)
            ])
        ]
        
        let reqBody = ArkChatRequest(
            model: modelName,
            messages: messages,
            temperature: 0.1,
            max_tokens: 300
        )
        
        // 发送请求
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(reqBody)
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        
        guard let httpResp = resp as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }
        
        guard httpResp.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.httpError(httpResp.statusCode, errorText)
        }
        
        let decoded = try JSONDecoder().decode(ArkChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw AIError.emptyResponse
        }
        
        // 解析全局AI响应
        return try parseGlobalAIResponse(content, devices: devices)
    }
    
    // MARK: - 私有方法
    
    /// 构建全局系统提示词 - 深度控制结构理解
    private func buildGlobalSystemPrompt() -> String {
        return """
你是智能家居全局控制助手。我将为你提供完整的设备控制结构树，你需要深度理解每个设备的控制分组和具体选项，然后精确匹配用户意图。

【第1步：理解设备控制结构】
每个设备包含：
- device_name：设备名称
- device_type：设备类型（灯具/风扇/插座等）
- location：设备位置（客厅/卧室等）
- control_structure：完整的控制分组结构
  - groups：控制分组列表（如"控制一"、"控制二"）
  - 每个分组包含多个options（如"控制一-1"、"控制一-2"）
- all_available_actions：所有可用动作的完整描述

【第2步：用户意图识别】
- 识别目标设备：从位置词（客厅/卧室）+ 设备类型词（灯/风扇）定位设备
- 识别控制意图：开/关/调节/模式切换等
- 识别具体参数：亮度/风速/温度/颜色/特效等

【第3步：设备定位】
- 优先匹配location + device_type组合
- 如果用户只说了设备类型，选择最可能的设备
- 如果用户只说了位置，根据意图推断设备类型

【第4步：控制分组分析】
- 查看目标设备的control_structure.groups
- 根据用户意图确定应该使用哪个控制分组
- 例如：用户说"调亮度"→寻找包含亮度相关选项的分组
- 例如：用户说"开关"→寻找包含电源相关选项的分组

【第5步：具体选项匹配】
- 在确定的控制分组内，查看所有options
- 匹配option_name和action_type与用户意图
- 选择最精确的选项（控制X-Y格式）

【第6步：最终确认】
- 确保选择的topic和payload来自匹配的选项
- 评估匹配置信度
- 生成详细的explanation说明匹配过程

【输出格式】
仅输出JSON：{"device_name":"设备名","topic":"完整topic","payload":"完整payload","confidence":0.95,"explanation":"详细匹配过程"}

【匹配示例思路】
用户："把客厅灯调亮"
1. 定位设备：客厅+灯→找到"客厅灯"
2. 理解控制结构：查看该设备的groups
3. 分析意图：调亮→寻找亮度相关的控制分组
4. 匹配选项：在亮度分组中找到"调亮"或"高亮度"选项
5. 输出：对应的topic和payload

请严格按照设备控制结构进行匹配，仅输出JSON。
"""
    }
    
    /// 构建所有设备的增强上下文信息（包含完整控制结构树）
    private func buildDevicesContext(devices: [Device]) -> [[String: Any]] {
        return devices.compactMap { device in
            guard let config = device.mqttConfig else { return nil }
            
            // 按控制分组整理命令
            let groupedCommands = Dictionary(grouping: config.commands) { $0.groupLabel }
            let controlGroups = groupedCommands.map { (groupLabel, commands) in
                [
                    "group_name": groupLabel,
                    "group_description": "控制分组：\(groupLabel)",
                    "options": commands.enumerated().map { (index, command) in
                        [
                            "option_id": "\(groupLabel)-\(index + 1)",
                            "option_name": command.label,
                            "full_description": "\(groupLabel)-\(index + 1)：\(command.label)",
                            "topic": command.topic,
                            "payload": command.payload,
                            "expected_state": command.expectedState ?? "",
                            "action_type": inferActionType(from: command.label, expectedState: command.expectedState)
                        ]
                    }
                ]
            }.sorted { ($0["group_name"] as? String ?? "") < ($1["group_name"] as? String ?? "") }
            
            return [
                "device_name": device.name,
                "device_type": inferDeviceType(from: device.name),
                "location": inferLocation(from: device.name),
                "control_topic": config.controlTopic,
                "state_topic": config.stateTopic ?? "",
                "control_structure": [
                    "total_groups": controlGroups.count,
                    "groups": controlGroups
                ],
                "all_available_actions": config.commands.enumerated().map { (index, command) in
                    "\(command.groupLabel)-\(getCommandIndexInGroup(command, in: config.commands) + 1)：\(command.label) → topic:\(command.topic), payload:\(command.payload)"
                }
            ]
        }
    }
    
    /// 推断设备类型
    private func inferDeviceType(from deviceName: String) -> String {
        let name = deviceName.lowercased()
        if name.contains("灯") || name.contains("light") || name.contains("lamp") {
            return "灯具"
        } else if name.contains("风扇") || name.contains("fan") {
            return "风扇"
        } else if name.contains("插座") || name.contains("outlet") || name.contains("socket") {
            return "插座"
        } else if name.contains("空调") || name.contains("aircon") || name.contains("ac") {
            return "空调"
        } else if name.contains("窗帘") || name.contains("curtain") {
            return "窗帘"
        } else {
            return "未知设备"
        }
    }
    
    /// 推断设备位置
    private func inferLocation(from deviceName: String) -> String {
        let name = deviceName.lowercased()
        if name.contains("客厅") || name.contains("living") {
            return "客厅"
        } else if name.contains("卧室") || name.contains("bedroom") {
            return "卧室"
        } else if name.contains("厨房") || name.contains("kitchen") {
            return "厨房"
        } else if name.contains("书房") || name.contains("study") {
            return "书房"
        } else if name.contains("阳台") || name.contains("balcony") {
            return "阳台"
        } else {
            return "未指定位置"
        }
    }
    
    /// 推断动作类型
    private func inferActionType(from label: String, expectedState: String?) -> String {
        let text = (label + (expectedState ?? "")).lowercased()
        if text.contains("开") || text.contains("on") || text.contains("打开") {
            return "开启"
        } else if text.contains("关") || text.contains("off") || text.contains("关闭") {
            return "关闭"
        } else if text.contains("亮") || text.contains("bright") || text.contains("高") {
            return "增强/调亮"
        } else if text.contains("暗") || text.contains("dim") || text.contains("低") {
            return "减弱/调暗"
        } else if text.contains("冷") || text.contains("cool") {
            return "制冷"
        } else if text.contains("热") || text.contains("heat") || text.contains("暖") {
            return "制热"
        } else if text.contains("自动") || text.contains("auto") {
            return "自动模式"
        } else {
            return "特殊控制"
        }
    }
    
    /// 获取命令在同组中的索引
    private func getCommandIndexInGroup(_ command: MQTTCommand, in allCommands: [MQTTCommand]) -> Int {
        let sameGroupCommands = allCommands.filter { $0.groupLabel == command.groupLabel }
        return sameGroupCommands.firstIndex(where: { $0.id == command.id }) ?? 0
    }
    
    /// 构建全局用户消息（增强版，包含结构化设备信息）
    private func buildGlobalUserMessage(userInput: String, devicesContext: [[String: Any]]) -> String {
        var message = "用户指令：\(userInput)\n\n"
        message += "=== 智能家居设备控制结构总览 ===\n\n"
        
        for (deviceIndex, deviceContext) in devicesContext.enumerated() {
            let deviceName = deviceContext["device_name"] as? String ?? "未知设备"
            let deviceType = deviceContext["device_type"] as? String ?? "未知类型"
            let location = deviceContext["location"] as? String ?? "未知位置"
            let controlTopic = deviceContext["control_topic"] as? String ?? ""
            
            message += "【设备\(deviceIndex + 1)】\(deviceName)\n"
            message += "- 类型：\(deviceType)\n"
            message += "- 位置：\(location)\n"
            message += "- 控制主题：\(controlTopic)\n"
            
            if let controlStructure = deviceContext["control_structure"] as? [String: Any],
               let groups = controlStructure["groups"] as? [[String: Any]] {
                message += "- 控制结构：\n"
                
                for group in groups {
                    let groupName = group["group_name"] as? String ?? "未知分组"
                    message += "  ◆ \(groupName)：\n"
                    
                    if let options = group["options"] as? [[String: Any]] {
                        for option in options {
                            let optionId = option["option_id"] as? String ?? ""
                            let optionName = option["option_name"] as? String ?? ""
                            let actionType = option["action_type"] as? String ?? ""
                            let topic = option["topic"] as? String ?? ""
                            let payload = option["payload"] as? String ?? ""
                            
                            message += "    • \(optionId)：\(optionName)（\(actionType)）→ topic:\(topic), payload:\(payload)\n"
                        }
                    }
                }
            }
            message += "\n"
        }
        
        message += "=== 匹配要求 ===\n"
        message += "1. 先根据用户指令定位目标设备\n"
        message += "2. 理解用户要控制的具体功能（电源/亮度/风速/特效等）\n"
        message += "3. 在对应设备的控制分组中找到最匹配的选项\n"
        message += "4. 返回该选项对应的完整topic和payload\n"
        message += "5. 必须严格使用上述结构中的topic和payload，不得修改\n\n"
        message += "请分析用户指令并返回JSON格式的控制命令。"
        
        return message
    }
    
    /// 解析全局AI响应
    private func parseGlobalAIResponse(_ content: String, devices: [Device]) throws -> GlobalPlannedResult {
        // 清理响应内容
        let cleanContent = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 解析JSON响应
        guard let data = cleanContent.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceName = json["device_name"] as? String,
              let topic = json["topic"] as? String,
              let payload = json["payload"] as? String,
              let confidence = json["confidence"] as? Double,
              let explanation = json["explanation"] as? String else {
            throw AIError.parseError(cleanContent)
        }
        
        // 查找对应的设备
        guard let device = devices.first(where: { $0.name == deviceName }) else {
            throw AIError.parseError("找不到设备：\(deviceName)")
        }
        
        let action = PlannedAction(
            topic: topic,
            payload: payload,
            confidence: confidence,
            explanation: explanation
        )
        
        return GlobalPlannedResult(
            device: device,
            action: action
        )
    }
}

// MARK: - 兜底规划器

/// 增强的兜底规划器（支持控制分组结构理解）
enum FallbackPlanner {
    static func plan(userInput: String, device: Device) -> PlannedAction? {
        guard let cfg = device.mqttConfig else { return nil }
        
        let lowered = userInput.lowercased()
        
        // 按控制分组整理命令，便于更精确的匹配
        let groupedCommands = Dictionary(grouping: cfg.commands) { $0.groupLabel }
        
        // 1. 优先匹配具体功能意图
        for (groupLabel, commands) in groupedCommands {
            // 电源控制分组
            if groupLabel.contains("电源") || groupLabel.contains("开关") || groupLabel.contains("power") {
                if lowered.contains("关") || lowered.contains("off") || lowered.contains("关闭") {
                    if let cmd = commands.first(where: { isOffCommand($0) }) {
                        return PlannedAction(
                            topic: cmd.topic,
                            payload: cmd.payload,
                            confidence: 0.8,
                            explanation: "兜底匹配：\(groupLabel)分组中的关闭命令（\(cmd.label)）"
                        )
                    }
                }
                if lowered.contains("开") || lowered.contains("on") || lowered.contains("打开") {
                    if let cmd = commands.first(where: { isOnCommand($0) }) {
                        return PlannedAction(
                            topic: cmd.topic,
                            payload: cmd.payload,
                            confidence: 0.8,
                            explanation: "兜底匹配：\(groupLabel)分组中的开启命令（\(cmd.label)）"
                        )
                    }
                }
            }
            
            // 亮度控制分组
            if groupLabel.contains("亮度") || groupLabel.contains("brightness") || groupLabel.contains("light") {
                if lowered.contains("亮") || lowered.contains("bright") || lowered.contains("高") {
                    if let cmd = commands.first(where: { isBrightenCommand($0) }) {
                        return PlannedAction(
                            topic: cmd.topic,
                            payload: cmd.payload,
                            confidence: 0.7,
                            explanation: "兜底匹配：\(groupLabel)分组中的调亮命令（\(cmd.label)）"
                        )
                    }
                }
                if lowered.contains("暗") || lowered.contains("dim") || lowered.contains("低") {
                    if let cmd = commands.first(where: { isDimCommand($0) }) {
                        return PlannedAction(
                            topic: cmd.topic,
                            payload: cmd.payload,
                            confidence: 0.7,
                            explanation: "兜底匹配：\(groupLabel)分组中的调暗命令（\(cmd.label)）"
                        )
                    }
                }
            }
        }
        
        // 2. 通用关键词匹配（如果没有找到分组匹配）
        if lowered.contains("关") || lowered.contains("off") || lowered.contains("关闭") {
            if let cmd = cfg.commands.first(where: { isOffCommand($0) }) {
                return PlannedAction(
                    topic: cmd.topic,
                    payload: cmd.payload,
                    confidence: 0.5,
                    explanation: "通用关键词匹配：关闭命令（\(cmd.label)）"
                )
            }
        }
        
        if lowered.contains("开") || lowered.contains("on") || lowered.contains("打开") {
            if let cmd = cfg.commands.first(where: { isOnCommand($0) }) {
                return PlannedAction(
                    topic: cmd.topic,
                    payload: cmd.payload,
                    confidence: 0.5,
                    explanation: "通用关键词匹配：开启命令（\(cmd.label)）"
                )
            }
        }
        
        // 3. 默认选择第一个命令
        if let first = cfg.commands.first {
            return PlannedAction(
                topic: first.topic,
                payload: first.payload,
                confidence: 0.2,
                explanation: "无法匹配具体意图，使用默认命令（\(first.groupLabel)-\(first.label)）"
            )
        }
        
        return nil
    }
    
    // MARK: - 辅助方法
    
    private static func isOffCommand(_ command: MQTTCommand) -> Bool {
        let text = (command.label + (command.expectedState ?? "")).lowercased()
        return text.contains("关") || text.contains("off") || 
               command.payload.lowercased().contains("guan") ||
               command.expectedState?.lowercased() == "off"
    }
    
    private static func isOnCommand(_ command: MQTTCommand) -> Bool {
        let text = (command.label + (command.expectedState ?? "")).lowercased()
        return text.contains("开") || text.contains("on") || 
               command.payload.lowercased().contains("kai") ||
               command.expectedState?.lowercased() == "on"
    }
    
    private static func isBrightenCommand(_ command: MQTTCommand) -> Bool {
        let text = command.label.lowercased()
        return text.contains("亮") || text.contains("bright") || text.contains("高") || text.contains("强")
    }
    
    private static func isDimCommand(_ command: MQTTCommand) -> Bool {
        let text = command.label.lowercased()
        return text.contains("暗") || text.contains("dim") || text.contains("低") || text.contains("弱")
    }
}

// MARK: - 错误定义

enum AIError: LocalizedError {
    case noMQTTConfig
    case invalidResponse
    case httpError(Int, String)
    case emptyResponse
    case parseError(String)
    
    var errorDescription: String? {
        switch self {
        case .noMQTTConfig:
            return "设备未配置MQTT控制"
        case .invalidResponse:
            return "无效的API响应"
        case .httpError(let code, let message):
            return "HTTP错误 \(code): \(message)"
        case .emptyResponse:
            return "AI返回空响应"
        case .parseError(let content):
            return "无法解析AI响应为JSON格式: \(content)"
        }
    }
}