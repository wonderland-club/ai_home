import SwiftUI
import SwiftData

struct DeviceListView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var mqtt: MQTTManager
    @Query(sort: \Device.name) private var devices: [Device]
    @Query private var settingsList: [AppSettings]
    @State private var isPresentingAdd = false
    
    // 全局AI控制状态
    @State private var globalAIInput: String = ""
    @State private var isAIThinking: Bool = false
    @State private var aiFeedback: String?
    @State private var showAIFeedback: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 全局AI控制区域
                globalAIControlSection
                
                List {
                    ForEach(devices) { device in
                    NavigationLink(destination: DeviceDetailView(device: device)) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).font(.headline)
                                Text(device.controlChannel == .mqtt ? "MQTT" : "HTTP")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            DeviceStateBadge(device: device)
                        }
                    }
                    }
                    .onDelete { indexSet in
                        indexSet.map { devices[$0] }.forEach(context.delete)
                        try? context.save()
                    }
                }
            }
            .navigationTitle("我的设备")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresentingAdd = true
                    } label: {
                        Label("添加设备", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingAdd) {
                AddDeviceView()
            }
            .alert("AI控制结果", isPresented: $showAIFeedback) {
                Button("确定") { showAIFeedback = false }
            } message: {
                Text(aiFeedback ?? "")
            }
        }
    }
    
    // MARK: - 全局AI控制区域
    private var globalAIControlSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.accentColor)
                Text("AI智能控制")
                    .font(.headline)
                    .foregroundColor(.accentColor)
                Spacer()
            }
            
            VStack(spacing: 8) {
                TextField("说出你想控制的设备和动作，如：把客厅的灯关了", text: $globalAIInput, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Button(action: runGlobalAIControl) {
                        HStack {
                            if isAIThinking {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("AI分析中...")
                            } else {
                                Image(systemName: "wand.and.stars")
                                Text("智能控制")
                            }
                        }
                    }
                    .disabled(isAIThinking || globalAIInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || devices.isEmpty)
                    .buttonStyle(.borderedProminent)
                    
                    Spacer()
                    
                    if !globalAIInput.isEmpty {
                        Button("清空", action: { globalAIInput = "" })
                            .buttonStyle(.bordered)
                    }
                }
            }
            
            Text("示例：\"把客厅灯关了\"、\"开启卧室风扇\"、\"调亮书房台灯\"")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    // MARK: - 全局AI控制方法
    private func runGlobalAIControl() {
        isAIThinking = true
        
        Task {
            defer { 
                Task { @MainActor in
                    isAIThinking = false
                }
            }
            
            do {
                let result = try await processGlobalAICommand(globalAIInput)
                await MainActor.run {
                    aiFeedback = result
                    showAIFeedback = true
                    globalAIInput = "" // 清空输入
                }
            } catch {
                await MainActor.run {
                    aiFeedback = "AI控制失败：\(error.localizedDescription)"
                    showAIFeedback = true
                }
            }
        }
    }
    
    private func processGlobalAICommand(_ input: String) async throws -> String {
        // 获取所有MQTT设备及其命令
        let mqttDevices = devices.filter { $0.controlChannel == .mqtt && $0.mqttConfig != nil }
        
        guard !mqttDevices.isEmpty else {
            throw NSError(domain: "GlobalAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有可控制的MQTT设备"])
        }
        
        // 尝试使用AI规划器
        guard let settings = settingsList.first,
              let baseURLString = settings.aiBaseURL,
              let baseURL = URL(string: baseURLString),
              let apiKey = KeychainHelper.read("doubao_api_key"),
              !apiKey.isEmpty else {
            // 无AI配置，使用兜底规划器
            return try useGlobalFallbackPlanner(input: input, devices: mqttDevices)
        }
        
        let planner = GlobalArkAIPlanner(endpoint: baseURL, apiKey: apiKey, modelName: settings.aiModelName)
        let result = try await planner.planGlobal(userInput: input, devices: mqttDevices)
        
        // 执行AI规划的动作
        if let config = result.device.mqttConfig {
            let tempCommand = MQTTCommand(
                label: "全局AI执行",
                payload: result.action.payload,
                expectedState: nil,
                order: 0,
                groupKey: nil,
                groupLabel: "全局AI",
                topic: result.action.topic
            )
            mqtt.send(command: tempCommand, using: config)
            
            let confidenceText = String(format: "%.0f%%", result.action.confidence * 100)
            return "✅ 已控制【\(result.device.name)】：\(result.action.explanation)\n置信度：\(confidenceText)"
        } else {
            throw NSError(domain: "GlobalAI", code: -2, userInfo: [NSLocalizedDescriptionKey: "设备配置错误"])
        }
    }
    
    private func useGlobalFallbackPlanner(input: String, devices: [Device]) throws -> String {
        // 简单的关键词匹配兜底逻辑
        let lowered = input.lowercased()
        
        // 尝试匹配设备名称
        var matchedDevice: Device?
        for device in devices {
            if lowered.contains(device.name.lowercased()) {
                matchedDevice = device
                break
            }
        }
        
        // 如果没有匹配到设备名称，使用第一个设备
        if matchedDevice == nil {
            matchedDevice = devices.first
        }
        
        guard let device = matchedDevice,
              let config = device.mqttConfig else {
            throw NSError(domain: "GlobalAI", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法找到合适的设备"])
        }
        
        // 匹配动作
        var matchedCommand: MQTTCommand?
        if lowered.contains("关") || lowered.contains("off") {
            matchedCommand = config.commands.first { cmd in
                cmd.payload.lowercased().contains("guan") ||
                cmd.expectedState?.lowercased() == "off" ||
                cmd.label.contains("关")
            }
        } else if lowered.contains("开") || lowered.contains("on") {
            matchedCommand = config.commands.first { cmd in
                cmd.payload.lowercased().contains("kai") ||
                cmd.expectedState?.lowercased() == "on" ||
                cmd.label.contains("开")
            }
        }
        
        // 如果没有匹配到具体动作，使用第一个命令
        if matchedCommand == nil {
            matchedCommand = config.commands.first
        }
        
        guard let command = matchedCommand else {
            throw NSError(domain: "GlobalAI", code: -4, userInfo: [NSLocalizedDescriptionKey: "设备没有可用的控制命令"])
        }
        
        // 执行命令
        mqtt.send(command: command, using: config)
        
        return "✅ 已控制【\(device.name)】：\(command.label)（兜底匹配）"
    }
}

struct DeviceStateBadge: View {
    let device: Device

    var body: some View {
        Text("#\(device.mqttConfig?.commands.count ?? device.httpConfig?.commands.count ?? 0)")
            .font(.caption)
            .padding(6)
            .background(.quaternary, in: Capsule())
    }
}
