import SwiftUI
import SwiftData

struct DeviceDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var mqtt: MQTTManager
    @Query private var settingsList: [AppSettings]
    @Bindable var device: Device

    @State private var httpFeedback: String?
    @State private var isSendingHTTP = false
    @State private var isPresentingEdit = false

    var body: some View {
        Form {
            basicSection
            
            if device.controlChannel == .mqtt {
                mqttSection
            } else {
                httpSection
            }
            if let httpFeedback, device.controlChannel == .http {
                Section("最近一次请求") {
                    Text(httpFeedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(device.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("编辑") { isPresentingEdit = true }
            }
        }
        .sheet(isPresented: $isPresentingEdit) {
            EditDeviceView(device: device)
                .environmentObject(mqtt)
        }
    }

    private var basicSection: some View {
        Section("设备信息") {
            TextField("名称", text: $device.name)
            Text("通道：\(device.controlChannel == .mqtt ? "MQTT" : "HTTP")")
            if let config = device.mqttConfig, device.controlChannel == .mqtt {
                Text("控制 Topic：\(config.controlTopic)")
                if let state = config.stateTopic, !state.isEmpty {
                    Text("状态 Topic：\(state)")
                        .foregroundStyle(.secondary)
                }
            }
            if let config = device.httpConfig, device.controlChannel == .http {
                Text("控制接口：\(config.controlMethod.rawValue) \(config.controlEndpoint)")
                if let status = config.statusEndpoint, !status.isEmpty {
                    Text("状态接口：\(config.statusMethod.rawValue) \(status)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var mqttSection: some View {
        Section("MQTT 控制") {
            if let config = device.mqttConfig {
                let groups = groupedCommands(config.commands)
                if groups.isEmpty {
                    ContentUnavailableView("尚未配置控制动作", systemImage: "slider.horizontal.3")
                } else {
                    ForEach(groups, id: \.key) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.label)
                                .font(.headline)
                            AdaptiveButtonGrid(commands: group.actions) { command in
                                mqtt.send(command: command, using: config)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            } else {
                ContentUnavailableView("未配置 MQTT 控制", systemImage: "wifi.slash")
            }
        }
    }

    private var httpSection: some View {
        Section("HTTP 控制") {
            if let config = device.httpConfig {
                if config.commands.isEmpty {
                    ContentUnavailableView("尚未配置控制动作", systemImage: "slider.horizontal.3")
                } else {
                    ForEach(config.commands.sorted(by: { $0.order < $1.order })) { command in
                        Button(command.label) {
                            sendHTTPCommand(command, config: config)
                        }
                        .disabled(isSendingHTTP)
                    }
                }
            } else {
                ContentUnavailableView("未配置 HTTP 控制", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        }
    }

    private func groupedCommands(_ commands: [MQTTCommand]) -> [CommandGroup] {
        let sorted = commands.sorted(by: { $0.order < $1.order })
        let grouped = Dictionary(grouping: sorted) { $0.groupKey ?? "group" }
        return grouped.map { key, commands in
            CommandGroup(key: key,
                         label: commands.first?.groupLabel ?? "控制",
                         actions: commands)
        }.sorted(by: { $0.label < $1.label })
    }

    private func sendHTTPCommand(_ command: HTTPCommand, config: HTTPConfig) {
        guard let settings = settingsList.first else { return }
        isSendingHTTP = true
        httpFeedback = "发送中..."
        let client = HTTPClient(settings: settings, overrideHeaderText: config.headersOverride)
        Task {
            do {
                let (_, response) = try await client.send(path: config.controlEndpoint,
                                                          method: config.controlMethod,
                                                          body: command.body)
                await MainActor.run {
                    httpFeedback = "成功：\(response.httpDescription)"
                    isSendingHTTP = false
                }
            } catch {
                await MainActor.run {
                    httpFeedback = "失败：\(error.localizedDescription)"
                    isSendingHTTP = false
                }
            }
        }
    }
}

private struct CommandGroup {
    let key: String
    let label: String
    let actions: [MQTTCommand]
}

private struct AdaptiveButtonGrid: View {
    let commands: [MQTTCommand]
    let action: (MQTTCommand) -> Void

    private let minWidth: CGFloat = 140
    private let minHeight: CGFloat = 56
    private let spacing: CGFloat = 12

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: spacing)], spacing: spacing) {
            ForEach(commands, id: \.id) { command in
                ControlActionTile(label: command.label,
                                  minHeight: minHeight,
                                  tap: { action(command) })
            }
        }
    }
}

private struct ControlActionTile: View {
    let label: String
    let minHeight: CGFloat
    let tap: () -> Void

    @State private var isPressed: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(isPressed ? 0.25 : 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                )
            Text(label)
                .font(.headline)
                .foregroundColor(.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            tap()
        }
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.15)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}
private extension URLResponse {
    var httpDescription: String {
        if let response = self as? HTTPURLResponse {
            return "HTTP \(response.statusCode)"
        }
        return "非 HTTP 响应"
    }
}

struct EditDeviceView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var mqtt: MQTTManager
    @Environment(\.dismiss) private var dismiss
    @Bindable var device: Device

    @State private var deviceIdentifier: String = ""
    @State private var name: String = ""
    @State private var controlTopic: String = ""
    @State private var stateTopic: String = ""
    @State private var controls: [ControlDraft] = []
    @State private var validationMessage: String?

    init(device: Device) {
        self._device = Bindable(device)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基础") {
                    TextField("设备标识", text: $deviceIdentifier)
                        .disabled(true)
                    TextField("显示名称", text: $name)
                    TextField("控制主题", text: $controlTopic)
                        .disableAutocorrection(true)
                    TextField("状态主题（可选）", text: $stateTopic)
                        .disableAutocorrection(true)
                        .foregroundColor(.secondary)
                }

                Section("控制列表") {
                    if controls.isEmpty {
                        ContentUnavailableView("还没有控制项", systemImage: "slider.horizontal.3")
                    }
                    ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                        ControlEditor(index: index,
                                      control: binding(for: control.id),
                                      removeControl: { controls.removeAll { $0.id == control.id } })
                    }
                    Button {
                        controls.append(ControlDraft(label: "控制 \(controls.count + 1)", actions: [ActionDraft(label: "动作", payload: "")]))
                    } label: {
                        Label("新增控制", systemImage: "plus")
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("保存修改") { saveChanges() }
                        .disabled(!isSaveEnabled)
                }
            }
            .navigationTitle("编辑设备")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear(perform: loadDraft)
        }
    }

    private func binding(for id: UUID) -> Binding<ControlDraft> {
        guard let index = controls.firstIndex(where: { $0.id == id }) else {
            return .constant(ControlDraft(label: "", actions: []))
        }
        return $controls[index]
    }

    private func loadDraft() {
        name = device.name
        deviceIdentifier = device.name
        if let config = device.mqttConfig {
            controlTopic = config.controlTopic
            stateTopic = config.stateTopic ?? ""
            controls = .from(config: config)
        } else {
            controlTopic = ""
            stateTopic = ""
            controls = .defaults()
        }
        if controls.isEmpty {
            controls = .defaults()
        }
    }

    private var isSaveEnabled: Bool {
        !controlTopic.trimmingCharacters(in: .whitespaces).isEmpty && controls.contains { control in
            control.actions.contains { !$0.payload.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    private func saveChanges() {
        validationMessage = nil
        guard isSaveEnabled else {
            validationMessage = "请填写控制主题并至少添加一个动作"
            return
        }

        device.name = name.isEmpty ? deviceIdentifier : name

        let config: MQTTConfig
        if let existing = device.mqttConfig {
            config = existing
        } else {
            let newConfig = MQTTConfig(stateTopic: nil, controlTopic: controlTopic)
            context.insert(newConfig)
            device.mqttConfig = newConfig
            config = newConfig
        }

        config.controlTopic = controlTopic
        config.stateTopic = stateTopic.trimmingCharacters(in: .whitespaces).isEmpty ? nil : stateTopic

        for command in config.commands {
            context.delete(command)
        }
        config.commands.removeAll()

        var orderCounter = 0
        for (index, control) in controls.enumerated() {
            let groupKey = "control_\(index)"
            let groupLabel = control.label.isEmpty ? "控制 \(index + 1)" : control.label
            let suffix = control.topicSuffix.trimmingCharacters(in: .whitespaces)
            let finalTopic = controlTopic + suffix
            for action in control.actions {
                let payload = action.payload.trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty else { continue }
                let label = action.label.isEmpty ? "动作 \(orderCounter + 1)" : action.label
                let command = MQTTCommand(label: label,
                                           payload: payload,
                                           expectedState: nil,
                                           order: orderCounter,
                                           groupKey: groupKey,
                                           groupLabel: groupLabel,
                                           topic: finalTopic)
                context.insert(command)
                command.config = config
                orderCounter += 1
            }
        }

        guard orderCounter > 0 else {
            validationMessage = "至少需要一个有效动作"
            return
        }

        do {
            try context.save()
            mqtt.resubscribeAllDevices()
            dismiss()
        } catch {
            validationMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}
