# iOS Home Control MVP (SwiftUI + SwiftData + CocoaMQTT)

## 1. Goals & Scope
- Build a native iOS 17+ SwiftUI app that persists devices with SwiftData.
- Support device CRUD, multiple state categories (switchable, numeric, mode).
- Connect to public MQTT and HTTP backends for control and telemetry.
- Provide a settings screen for MQTT and HTTP configuration, persisting secrets in Keychain.
- Explicitly excluded from the MVP: accounts, multi-tenant flows, push, advanced background handling, voice/AI helpers.

## 2. Tooling & Dependencies
- **Xcode**: 15.4+
- **Minimum iOS**: 17 (needed for SwiftData)
- **Package Manager**: Swift Package Manager
  - Add `CocoaMQTT` from `https://github.com/emqx/CocoaMQTT.git`
- **System Frameworks**: `SwiftUI`, `SwiftData`, `Combine`, `Foundation`

### Add CocoaMQTT via SPM
1. File ▸ Add Packages…
2. Search or enter URL: `https://github.com/emqx/CocoaMQTT.git`
3. Use the latest 2.x release, add to the app target.

## 3. Data Modeling (SwiftData)
Persist devices and configuration in SwiftData; keep sensitive secrets in Keychain.

```swift
// Models.swift
enum DeviceType: String, Codable, CaseIterable { case light, outlet, thermostat, sensor, custom }

enum StateCategory: String, Codable, CaseIterable { case switchable, numeric, mode }

@Model
final class Device {
    @Attribute(.unique) var id: UUID
    var name: String
    var type: DeviceType
    var stateCategory: StateCategory
    var boolState: Bool
    var numberState: Double?
    var modeState: String?
    var mqttTopicState: String
    var mqttTopicCommand: String
    var httpEndpoint: String?
    init(id: UUID = UUID(),
         name: String,
         type: DeviceType,
         stateCategory: StateCategory,
         boolState: Bool = false,
         numberState: Double? = nil,
         modeState: String? = nil,
         mqttTopicState: String,
         mqttTopicCommand: String,
         httpEndpoint: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.stateCategory = stateCategory
        self.boolState = boolState
        self.numberState = numberState
        self.modeState = modeState
        self.mqttTopicState = mqttTopicState
        self.mqttTopicCommand = mqttTopicCommand
        self.httpEndpoint = httpEndpoint
    }
}

@Model
final class AppSettings {
    var mqttHost: String
    var mqttPort: Int
    var mqttUseTLS: Bool
    var mqttUsername: String?
    var mqttClientIdPrefix: String
    var httpBaseURL: String?
    var httpHeadersText: String
    init(mqttHost: String = "",
         mqttPort: Int = 8883,
         mqttUseTLS: Bool = true,
         mqttUsername: String? = nil,
         mqttClientIdPrefix: String = "ios-",
         httpBaseURL: String? = nil,
         httpHeadersText: String = "") {
        self.mqttHost = mqttHost
        self.mqttPort = mqttPort
        self.mqttUseTLS = mqttUseTLS
        self.mqttUsername = mqttUsername
        self.mqttClientIdPrefix = mqttClientIdPrefix
        self.httpBaseURL = httpBaseURL
        self.httpHeadersText = httpHeadersText
    }
}
```

## 4. Keychain Utilities
Store secrets such as MQTT password and HTTP tokens.

```swift
// KeychainHelper.swift
enum KeychainHelper {
    static func save(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        let add = query.merging([kSecValueData as String: data]) { $1 }
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        if let data = result as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }
}

// Suggested keys
// MQTT password: "mqtt_password"
// HTTP bearer token: "http_token"
```

## 5. Networking Layer

### MQTT Manager (CocoaMQTT)
Handles connection, topic subscriptions, and state synchronization.

```swift
// MQTTManager.swift
final class MQTTManager: NSObject, ObservableObject {
    @Published var connected = false
    @Published var lastMessage: (topic: String, payload: String)?

    private var mqtt: CocoaMQTT?
    private var topics: Set<String> = []
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func configureAndConnect(from settings: AppSettings) {
        guard !settings.mqttHost.isEmpty else { return }
        let clientID = settings.mqttClientIdPrefix + UUID().uuidString.prefix(8)

        let mqtt = CocoaMQTT(clientID: String(clientID),
                             host: settings.mqttHost,
                             port: UInt16(settings.mqttPort))
        mqtt.username = settings.mqttUsername
        mqtt.password = KeychainHelper.read("mqtt_password")
        mqtt.keepAlive = 60
        mqtt.autoReconnect = true
        mqtt.enableSSL = settings.mqttUseTLS
        mqtt.allowUntrustCACertificate = false
        mqtt.delegate = self
        self.mqtt = mqtt
        mqtt.connect()
    }

    func disconnect() { mqtt?.disconnect() }

    func resubscribeAllDevices() {
        let context = ModelContext(container)
        let fetch = FetchDescriptor<Device>()
        guard let devices = try? context.fetch(fetch) else { return }
        let newTopics = Set(devices.map { $0.mqttTopicState })
        topics.subtracting(newTopics).forEach { mqtt?.unsubscribe($0) }
        newTopics.subtracting(topics).forEach { mqtt?.subscribe($0, qos: .qos1) }
        topics = newTopics
    }

    func publishCommand(topic: String, payload: String, qos: CocoaMQTTQoS = .qos1) {
        mqtt?.publish(topic, withString: payload, qos: qos, retained: false)
    }
}

extension MQTTManager: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnect host: String, port: Int) {}
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        connected = ack == .accept
        if connected { resubscribeAllDevices() }
    }
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let payload = message.string ?? ""
        DispatchQueue.main.async {
            self.lastMessage = (topic: message.topic, payload: payload)
        }
        let context = ModelContext(container)
        guard let devices = try? context.fetch(FetchDescriptor<Device>()),
              let device = devices.first(where: { $0.mqttTopicState == message.topic }) else { return }
        switch device.stateCategory {
        case .switchable:
            device.boolState = ["on", "1", "true"].contains(payload.lowercased())
        case .numeric:
            device.numberState = Double(payload)
        case .mode:
            device.modeState = payload
        }
        try? context.save()
    }
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        connected = false
    }
}
```

### HTTP Client
Encapsulate basic control/status calls, merging headers from settings and Keychain.

```swift
// HTTPClient.swift
struct HTTPClient {
    let baseURL: URL?
    let headers: [String: String]

    init(settings: AppSettings) {
        baseURL = settings.httpBaseURL.flatMap(URL.init(string:))
        var h: [String: String] = [:]
        settings.httpHeadersText
            .split(separator: "\n")
            .map { $0.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) } }
            .forEach { if $0.count == 2 { h[$0[0]] = $0[1] } }
        if let token = KeychainHelper.read("http_token"), !token.isEmpty {
            h["Authorization"] = "Bearer \(token)"
        }
        headers = h
    }

    func postControl(path: String, body: [String: Any]) async throws -> (Data, URLResponse) {
        guard let baseURL else { throw URLError(.badURL) }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.allHTTPHeaderFields = headers.merging(["Content-Type": "application/json"]) { $1 }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.data(for: req)
    }

    func getStatus(path: String) async throws -> (Data, URLResponse) {
        guard let baseURL else { throw URLError(.badURL) }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.allHTTPHeaderFields = headers
        return try await URLSession.shared.data(for: req)
    }
}
```

> **ATS**: For non-HTTPS endpoints, add temporary `NSAppTransportSecurity` exceptions for development; revert to HTTPS before release.

## 6. SwiftUI App Structure
Use a `TabView` to host the device list, add-device flow, and settings.

### App Entry

```swift
// HomeControlApp.swift
@main
struct HomeControlApp: App {
    @State private var mqttManager: MQTTManager
    let container: ModelContainer

    init() {
        let schema = Schema([Device.self, AppSettings.self])
        container = try! ModelContainer(for: schema)
        _mqttManager = State(initialValue: MQTTManager(container: container))

        let context = ModelContext(container)
        if (try? context.fetch(FetchDescriptor<AppSettings>()).isEmpty) == true {
            context.insert(AppSettings())
            try? context.save()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .modelContainer(container)
                .environmentObject(mqttManager)
        }
    }
}
```

### Root Tabs

```swift
// RootTabView.swift
struct RootTabView: View {
    var body: some View {
        TabView {
            DeviceListView()
                .tabItem { Label("设备", systemImage: "switch.2") }
            AddDeviceView()
                .tabItem { Label("添加", systemImage: "plus.circle") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
```

### Device List & Detail

```swift
// DeviceListView.swift
struct DeviceListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Device.name) private var devices: [Device]

    var body: some View {
        NavigationStack {
            List {
                ForEach(devices) { device in
                    NavigationLink(value: device.id) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).font(.headline)
                                Text("\(device.type.rawValue) • \(device.stateCategory.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            DeviceStateBadge(device: device)
                        }
                    }
                }
                .onDelete { indexSet in indexSet.map { devices[$0] }.forEach(context.delete) }
            }
            .navigationTitle("我的设备")
            .navigationDestination(for: UUID.self) { id in
                if let device = devices.first(where: { $0.id == id }) {
                    DeviceDetailView(device: device)
                }
            }
        }
    }
}

struct DeviceStateBadge: View {
    let device: Device
    var body: some View {
        switch device.stateCategory {
        case .switchable:
            Text(device.boolState ? "ON" : "OFF")
                .bold()
                .foregroundStyle(device.boolState ? .green : .secondary)
        case .numeric:
            Text(device.numberState.map { String(format: "%.1f", $0) } ?? "--")
        case .mode:
            Text(device.modeState ?? "--")
        }
    }
}
```

```swift
// DeviceDetailView.swift
struct DeviceDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var mqtt: MQTTManager
    @Bindable var device: Device

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("名称", text: $device.name)
                Text("类型：\(device.type.rawValue)")
                Text("分类：\(device.stateCategory.rawValue)")
                Text("状态主题：\(device.mqttTopicState)")
                Text("控制主题：\(device.mqttTopicCommand)")
                if let endpoint = device.httpEndpoint {
                    Text("HTTP：\(endpoint)")
                }
            }

            Section("控制") {
                switch device.stateCategory {
                case .switchable:
                    Toggle("开关", isOn: $device.boolState)
                        .onChange(of: device.boolState) { _, newValue in
                            let payload = newValue ? "ON" : "OFF"
                            mqtt.publishCommand(topic: device.mqttTopicCommand, payload: payload)
                            try? context.save()
                        }
                case .numeric:
                    let binding = Binding(
                        get: { device.numberState ?? 0 },
                        set: { value in
                            device.numberState = value
                            try? context.save()
                            mqtt.publishCommand(topic: device.mqttTopicCommand, payload: String(value))
                        }
                    )
                    Stepper("数值：\(Int(binding.wrappedValue))", value: binding, in: 0...100, step: 1)
                case .mode:
                    let modes = ["auto", "cool", "heat", "off"]
                    Picker("模式", selection: Binding(
                        get: { device.modeState ?? "off" },
                        set: { value in
                            device.modeState = value
                            try? context.save()
                            mqtt.publishCommand(topic: device.mqttTopicCommand, payload: value)
                        }
                    )) {
                        ForEach(modes, id: \.self) { Text($0) }
                    }
                }
            }
        }
        .navigationTitle(device.name)
        .onReceive(mqtt.$lastMessage.compactMap { $0 }) { message in
            guard message.topic == device.mqttTopicState else { return }
            switch device.stateCategory {
            case .switchable:
                device.boolState = ["on", "1", "true"].contains(message.payload.lowercased())
            case .numeric:
                device.numberState = Double(message.payload)
            case .mode:
                device.modeState = message.payload
            }
            try? context.save()
        }
    }
}
```

### Add Device Flow

```swift
// AddDeviceView.swift
struct AddDeviceView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var mqtt: MQTTManager

    @State private var name = ""
    @State private var type: DeviceType = .light
    @State private var category: StateCategory = .switchable
    @State private var topicState = "devices/xxx/state"
    @State private var topicCommand = "devices/xxx/set"
    @State private var httpEndpoint = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("基础") {
                    TextField("设备名称", text: $name)
                    Picker("类型", selection: $type) {
                        ForEach(DeviceType.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    Picker("状态分类", selection: $category) {
                        ForEach(StateCategory.allCases, id: \.self) { Text($0.rawValue) }
                    }
                }
                Section("网络") {
                    TextField("MQTT 状态主题", text: $topicState)
                    TextField("MQTT 控制主题", text: $topicCommand)
                    TextField("HTTP 端点（可选）", text: $httpEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button("保存设备") {
                    let device = Device(
                        name: name.isEmpty ? "未命名设备" : name,
                        type: type,
                        stateCategory: category,
                        mqttTopicState: topicState,
                        mqttTopicCommand: topicCommand,
                        httpEndpoint: httpEndpoint.isEmpty ? nil : httpEndpoint
                    )
                    context.insert(device)
                    try? context.save()
                    mqtt.resubscribeAllDevices()
                    resetForm()
                }
                .disabled(topicState.isEmpty || topicCommand.isEmpty)
            }
            .navigationTitle("添加设备")
        }
    }

    private func resetForm() {
        name = ""
        type = .light
        category = .switchable
        topicState = "devices/xxx/state"
        topicCommand = "devices/xxx/set"
        httpEndpoint = ""
    }
}
```

### Settings Screen

```swift
// SettingsView.swift
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var mqtt: MQTTManager
    @Query private var settingsList: [AppSettings]

    @State private var mqttPassword = KeychainHelper.read("mqtt_password") ?? ""
    @State private var httpToken = KeychainHelper.read("http_token") ?? ""

    var body: some View {
        let settings = settingsList.first!
        Form {
            Section("MQTT（公共网络）") {
                TextField("Host", text: binding(\AppSettings.mqttHost, in: settings))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    TextField("Port", value: binding(\AppSettings.mqttPort, in: settings), format: .number)
                        .keyboardType(.numberPad)
                    Toggle("TLS", isOn: binding(\AppSettings.mqttUseTLS, in: settings))
                }
                TextField("用户名（可选）", text: Binding(
                    get: { settings.mqttUsername ?? "" },
                    set: { settings.mqttUsername = $0.isEmpty ? nil : $0 }
                ))
                SecureField("密码（Keychain）", text: $mqttPassword)
                TextField("ClientID 前缀", text: binding(\AppSettings.mqttClientIdPrefix, in: settings))
                Button("保存并连接") {
                    KeychainHelper.save(mqttPassword, for: "mqtt_password")
                    try? context.save()
                    mqtt.configureAndConnect(from: settings)
                }
                if mqtt.connected {
                    Label("已连接", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }

            Section("HTTP（公共网络）") {
                TextField("Base URL（https://…）", text: Binding(
                    get: { settings.httpBaseURL ?? "" },
                    set: { settings.httpBaseURL = $0.isEmpty ? nil : $0 }
                ))
                SecureField("Bearer Token（Keychain，可选）", text: $httpToken)
                TextEditor(text: binding(\AppSettings.httpHeadersText, in: settings))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                Button("保存 HTTP 配置") {
                    KeychainHelper.save(httpToken, for: "http_token")
                    try? context.save()
                }
            }
        }
        .navigationTitle("设置")
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>, in object: AppSettings) -> Binding<T> {
        Binding(
            get: { object[keyPath: keyPath] },
            set: { value in
                object[keyPath: keyPath] = value
                try? context.save()
            }
        )
    }
}
```

## 7. MQTT & HTTP Contract
- **MQTT Topics**: `devices/{deviceId}/state` for telemetry, `devices/{deviceId}/set` for commands.
  - Switchable payloads: `ON` / `OFF`
  - Numeric payloads: stringified numbers (`"42"`)
  - Mode payloads: string (`"auto"`, `"cool"`…)
- **HTTP Endpoints (optional)**:
  - `POST /devices/{id}/control` with `{ "status": "ON" }` or `{ "value": 23 }`
  - `GET /devices/{id}/status` returning current values

## 8. Security & Release Notes
- Prefer TLS (mqtts/8883, HTTPS). Keep `allowUntrustCACertificate` false for production.
- Secrets live only in Keychain; never persist them in SwiftData or plain files.
- If you need plaintext HTTP during development, add a scoped `NSAppTransportSecurity` exception and remove it before shipping.
- Limit entitlements to required capabilities; no background modes or push for the MVP.

## 9. Manual Test Checklist (Device)
- Configure MQTT/HTTP in Settings and save.
- Establish MQTT connection (status indicator turns green).
- Add devices and verify persisted topics/endpoints.
- Toggle switchable device; observe command on `.../set`.
- Receive telemetry on `.../state`; UI updates instantly.
- Relaunch app; devices and settings restore, MQTT resubscribes.
- (Optional) Trigger `HTTPClient.postControl` to validate HTTP path.

## 10. Extension Hooks
- **Groups & Scenes**: add grouping fields to `Device` and new list filters.
- **Voice/AI**: reuse `stateCategory` semantics to map voice intents to MQTT/HTTP actions.
- **Richer Capabilities**: refactor `Device` into `Device` + `DeviceCapability` models.

## 11. Integration Steps Summary
1. Create new Swift files with the snippets above (or copy into existing files).
2. Add CocoaMQTT via SPM and enable Keychain capability if not already on.
3. Run on a device to configure settings, add devices, and validate MQTT flows.
4. Iterate on HTTP actions or UI polish as needed.

With these components in place, you have a functional SwiftUI MVP that persists local device metadata, manages MQTT/HTTP connectivity over public networks, and exposes a UX for basic control and configuration.
