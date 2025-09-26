import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]

    var body: some View {
        NavigationStack {
            if let settings = settingsList.first {
                SettingsDetailView(settings: settings)
            } else {
                Text("正在初始化设置…")
                    .navigationTitle("设置")
                    .onAppear {
                        let settings = AppSettings()
                        context.insert(settings)
                        try? context.save()
                    }
            }
        }
    }
}

private struct SettingsDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var mqtt: MQTTManager
    @Bindable var settings: AppSettings

    @State private var mqttPassword: String = KeychainHelper.read("mqtt_password") ?? ""
    @State private var httpToken: String = KeychainHelper.read("http_token") ?? ""

    var body: some View {
        Form {
            Section("MQTT（公共网络）") {
                TextField("Host", text: $settings.mqttHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    TextField("Port", value: $settings.mqttPort, format: .number)
                        .keyboardType(.numberPad)
                    Toggle("TLS", isOn: $settings.mqttUseTLS)
                }
                Toggle("WebSocket", isOn: $settings.mqttUseWebSocket)
                TextField("WebSocket 路径", text: $settings.mqttWebSocketPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!settings.mqttUseWebSocket)
                TextField("用户名（可选）", text: Binding(
                    get: { settings.mqttUsername ?? "" },
                    set: { value in
                        settings.mqttUsername = value.isEmpty ? nil : value
                        try? context.save()
                    }
                ))
                SecureField("密码（Keychain）", text: $mqttPassword)
                TextField("ClientID 前缀", text: $settings.mqttClientIdPrefix)
                Button("保存并连接") {
                    KeychainHelper.save(mqttPassword, for: "mqtt_password")
                    try? context.save()
                    mqtt.configureAndConnect(from: settings)
                }
                Group {
                    switch mqtt.connectionState {
                    case .connected:
                        Label("已连接", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    case .connecting:
                        Label("连接中…", systemImage: "hourglass")
                            .foregroundStyle(.orange)
                    default:
                        Label("未连接", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("HTTP（公共网络）") {
                TextField("Base URL（https://…）", text: Binding(
                    get: { settings.httpBaseURL ?? "" },
                    set: { value in
                        settings.httpBaseURL = value.isEmpty ? nil : value
                        try? context.save()
                    }
                ))
                SecureField("Bearer Token（Keychain，可选）", text: $httpToken)
                TextEditor(text: $settings.httpHeadersText)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                Button("保存 HTTP 配置") {
                    KeychainHelper.save(httpToken, for: "http_token")
                    try? context.save()
                }
            }
        }
        .navigationTitle("设置")
        .onChange(of: settings.mqttHost) { _, _ in try? context.save() }
        .onChange(of: settings.mqttPort) { _, _ in try? context.save() }
        .onChange(of: settings.mqttUseTLS) { _, _ in try? context.save() }
        .onChange(of: settings.mqttUseWebSocket) { _, _ in try? context.save() }
        .onChange(of: settings.mqttWebSocketPath) { _, _ in try? context.save() }
        .onChange(of: settings.mqttClientIdPrefix) { _, _ in try? context.save() }
        .onChange(of: settings.httpHeadersText) { _, _ in try? context.save() }
    }
}
