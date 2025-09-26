import SwiftUI
import SwiftData

@main
struct ai_homeApp: App {
    @State private var mqttManager: MQTTManager
    let container: ModelContainer

    init() {
        let schema = Schema([
            Device.self,
            MQTTConfig.self,
            MQTTCommand.self,
            HTTPConfig.self,
            HTTPCommand.self,
            AppSettings.self
        ])
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storeURL = supportURL.appendingPathComponent("HomeControl_v3.store")
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(schema: schema, url: storeURL, allowsSave: true)
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            try? FileManager.default.removeItem(at: storeURL)
            container = try! ModelContainer(for: schema, configurations: configuration)
        }

        let manager = MQTTManager(container: container)
        _mqttManager = State(initialValue: manager)

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<AppSettings>()
        var settings: AppSettings

        if let existing = try? context.fetch(descriptor).first {
            if existing.mqttHost.isEmpty {
                existing.mqttHost = "mqtt.aimaker.space"
            }
            if existing.mqttPort == 0 {
                existing.mqttPort = 8084
            }
            if existing.mqttUsername == nil || existing.mqttUsername?.isEmpty == true {
                existing.mqttUsername = "guest"
            }
            existing.mqttUseWebSocket = true
            if existing.mqttWebSocketPath.isEmpty {
                existing.mqttWebSocketPath = "/mqtt"
            }
            settings = existing
        } else {
            let defaults = AppSettings()
            defaults.mqttUsername = "guest"
            context.insert(defaults)
            settings = defaults
        }

        try? context.save()

        if KeychainHelper.read("mqtt_password") == nil {
            KeychainHelper.save("test", for: "mqtt_password")
        }

        manager.configureAndConnect(from: settings)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .modelContainer(container)
                .environmentObject(mqttManager)
        }
    }
}
