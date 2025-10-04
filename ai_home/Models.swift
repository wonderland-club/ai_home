import Foundation
import SwiftData

enum DeviceType: String, Codable, CaseIterable {
    case light
    case outlet
    case thermostat
    case sensor
    case custom
}

enum StateCategory: String, Codable, CaseIterable {
    case switchable
    case numeric
    case mode
}

enum ControlChannel: String, Codable, CaseIterable {
    case mqtt
    case http
}

enum HTTPMethod: String, Codable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
}

@Model
final class Device {
    @Attribute(.unique) var id: UUID
    var name: String
    var type: DeviceType
    var stateCategory: StateCategory
    var controlChannel: ControlChannel

    // —— 状态值（按分类使用其一，为 MVP 简化）
    var boolState: Bool
    var numberState: Double?
    var modeState: String?

    // —— 配置关联
    @Relationship(deleteRule: .cascade) var mqttConfig: MQTTConfig?
    @Relationship(deleteRule: .cascade) var httpConfig: HTTPConfig?

    init(id: UUID = UUID(),
         name: String,
         type: DeviceType,
         stateCategory: StateCategory,
         controlChannel: ControlChannel,
         boolState: Bool = false,
         numberState: Double? = nil,
         modeState: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.stateCategory = stateCategory
        self.controlChannel = controlChannel
        self.boolState = boolState
        self.numberState = numberState
        self.modeState = modeState
    }
}

@Model
final class MQTTConfig {
    @Attribute(.unique) var id: UUID
    var stateTopic: String?
    var controlTopic: String
    @Relationship(deleteRule: .cascade, inverse: \MQTTCommand.config) var commands: [MQTTCommand]

    init(id: UUID = UUID(),
         stateTopic: String? = nil,
         controlTopic: String,
         commands: [MQTTCommand] = []) {
        self.id = id
        self.stateTopic = stateTopic
        self.controlTopic = controlTopic
        self.commands = commands
    }
}

@Model
final class MQTTCommand {
    @Attribute(.unique) var id: UUID
    var label: String
    var payload: String
    var qos: Int
    var shouldRetain: Bool
    /// 命令执行后期望的状态字符串（例如 "on"/"off"/"cool"）
    var expectedState: String?
    var order: Int
    var groupKey: String?
    var groupLabel: String
    var topic: String
    @Relationship var config: MQTTConfig?

    init(id: UUID = UUID(),
         label: String,
         payload: String,
         qos: Int = 1,
         shouldRetain: Bool = false,
         expectedState: String? = nil,
         order: Int = 0,
         groupKey: String? = nil,
         groupLabel: String = "",
         topic: String) {
        self.id = id
        self.label = label
        self.payload = payload
        self.qos = qos
        self.shouldRetain = shouldRetain
        self.expectedState = expectedState
        self.order = order
        self.groupKey = groupKey
        self.groupLabel = groupLabel
        self.topic = topic
    }
}

@Model
final class HTTPConfig {
    @Attribute(.unique) var id: UUID
    var statusEndpoint: String?
    var statusMethodRaw: String
    var controlEndpoint: String
    var controlMethodRaw: String
    var headersOverride: String
    @Relationship(deleteRule: .cascade, inverse: \HTTPCommand.config) var commands: [HTTPCommand]

    init(id: UUID = UUID(),
         statusEndpoint: String? = nil,
         statusMethod: HTTPMethod = .get,
         controlEndpoint: String,
         controlMethod: HTTPMethod = .post,
         headersOverride: String = "",
         commands: [HTTPCommand] = []) {
        self.id = id
        self.statusEndpoint = statusEndpoint
        self.statusMethodRaw = statusMethod.rawValue
        self.controlEndpoint = controlEndpoint
        self.controlMethodRaw = controlMethod.rawValue
        self.headersOverride = headersOverride
        self.commands = commands
    }

    var statusMethod: HTTPMethod { HTTPMethod(rawValue: statusMethodRaw) ?? .get }
    var controlMethod: HTTPMethod { HTTPMethod(rawValue: controlMethodRaw) ?? .post }
}

@Model
final class HTTPCommand {
    @Attribute(.unique) var id: UUID
    var label: String
    /// JSON 内容或其他 body 文本
    var body: String
    /// 执行后期望的状态值
    var expectedState: String?
    var order: Int
    @Relationship var config: HTTPConfig?

    init(id: UUID = UUID(),
         label: String,
         body: String,
         expectedState: String? = nil,
         order: Int = 0) {
        self.id = id
        self.label = label
        self.body = body
        self.expectedState = expectedState
        self.order = order
    }
}

@Model
final class AppSettings {
    var mqttHost: String = "mqtt.aimaker.space"
    var mqttPort: Int = 8084
    var mqttUseTLS: Bool = true
    var mqttUseWebSocket: Bool = true
    var mqttWebSocketPath: String = "/mqtt"
    var mqttUsername: String?
    var mqttClientIdPrefix: String = "ios-"
    var httpBaseURL: String?
    var httpHeadersText: String = ""
    
    // AI配置
    var aiBaseURL: String? // 豆包Ark API端点
    var aiModelName: String = "ep-20250717003424-g4btn" // 默认使用示例接入点ID

    init(mqttHost: String = "mqtt.aimaker.space",
         mqttPort: Int = 8084,
         mqttUseTLS: Bool = true,
         mqttUseWebSocket: Bool = true,
         mqttWebSocketPath: String = "/mqtt",
         mqttUsername: String? = nil,
         mqttClientIdPrefix: String = "ios-",
         httpBaseURL: String? = nil,
         httpHeadersText: String = "",
         aiBaseURL: String? = nil,
         aiModelName: String = "ep-20250717003424-g4btn") {
        self.mqttHost = mqttHost
        self.mqttPort = mqttPort
        self.mqttUseTLS = mqttUseTLS
        self.mqttUseWebSocket = mqttUseWebSocket
        self.mqttWebSocketPath = mqttWebSocketPath
        self.mqttUsername = mqttUsername
        self.mqttClientIdPrefix = mqttClientIdPrefix
        self.httpBaseURL = httpBaseURL
        self.httpHeadersText = httpHeadersText
        self.aiBaseURL = aiBaseURL
        self.aiModelName = aiModelName
    }
}
