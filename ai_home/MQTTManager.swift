import Foundation
import Combine
import CocoaMQTT
import SwiftData

final class MQTTManager: NSObject, ObservableObject {
    @Published var connected: Bool = false
    @Published var lastMessage: (topic: String, payload: String)?
    @Published var connectionState: CocoaMQTTConnState = .disconnected

    private var mqtt: CocoaMQTT?
    private var topics: Set<String> = []
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func configureAndConnect(from settings: AppSettings) {
        guard !settings.mqttHost.isEmpty else { return }
        mqtt?.disconnect()
        mqtt = nil
        let suffix = UUID().uuidString.prefix(8)
        let clientID = settings.mqttClientIdPrefix + suffix
        let socket: CocoaMQTTSocketProtocol
        if settings.mqttUseWebSocket {
            let websocket = MQTTWebSocket(uri: settings.mqttWebSocketPath)
            websocket.enableSSL = settings.mqttUseTLS
            websocket.headers["Sec-WebSocket-Protocol"] = "mqtt"
            socket = websocket
        } else {
            socket = CocoaMQTTSocket()
        }

        let mqtt = CocoaMQTT(clientID: String(clientID),
                             host: settings.mqttHost,
                             port: UInt16(settings.mqttPort),
                             socket: socket)
        mqtt.username = settings.mqttUsername
        mqtt.password = KeychainHelper.read("mqtt_password")
        mqtt.keepAlive = 60
        mqtt.autoReconnect = true
        mqtt.enableSSL = settings.mqttUseTLS
        mqtt.allowUntrustCACertificate = false
        mqtt.logLevel = .debug
        mqtt.delegate = self
        self.mqtt = mqtt
        connectionState = .connecting
        _ = mqtt.connect()
    }

    func disconnect() {
        mqtt?.disconnect()
    }

    func resubscribeAllDevices() {
        let context = ModelContext(container)
        let fetch = FetchDescriptor<Device>()
        guard let devices = try? context.fetch(fetch) else { return }
        let newTopics: Set<String> = Set(devices.compactMap { device in
            guard device.controlChannel == .mqtt,
                  let topic = device.mqttConfig?.stateTopic,
                  !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return topic
        })
        topics.subtracting(newTopics).forEach { mqtt?.unsubscribe($0) }
        newTopics.subtracting(topics).forEach { mqtt?.subscribe($0, qos: .qos1) }
        topics = newTopics
    }

    func send(command: MQTTCommand, using config: MQTTConfig) {
        let qosValue = max(0, min(2, command.qos))
        let qos = CocoaMQTTQoS(rawValue: UInt8(qosValue)) ?? .qos1
        let topic = command.topic.isEmpty ? config.controlTopic : command.topic
        mqtt?.publish(topic, withString: command.payload, qos: qos, retained: command.shouldRetain)
    }
}

extension MQTTManager: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnect host: String, port: Int) {}

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        connected = ack == .accept
        connectionState = connected ? .connected : .disconnected
        if connected { resubscribeAllDevices() }
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}

    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}

    func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {
        connectionState = state
    }

    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}

    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}

    func mqttDidPing(_ mqtt: CocoaMQTT) {}

    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}

    func mqtt(_ mqtt: CocoaMQTT, didPublishComplete id: UInt16) {}

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let payload = message.string ?? ""
        DispatchQueue.main.async {
            self.lastMessage = (topic: message.topic, payload: payload)
        }
        let context = ModelContext(container)
        guard let devices = try? context.fetch(FetchDescriptor<Device>()) else { return }
        let matchedDevices = devices.filter {
            $0.controlChannel == .mqtt && $0.mqttConfig?.stateTopic == message.topic
        }
        guard !matchedDevices.isEmpty else { return }
        matchedDevices.forEach { device in
            _ = device.mqttConfig // currently a placeholder for future state sync
        }
        try? context.save()
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        connected = false
        connectionState = .disconnected
    }
}
