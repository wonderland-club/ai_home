import SwiftUI
import SwiftData

struct ActionDraft: Identifiable, Equatable {
    let id: UUID
    var label: String
    var payload: String

    init(id: UUID = UUID(), label: String, payload: String) {
        self.id = id
        self.label = label
        self.payload = payload
    }
}

struct ControlDraft: Identifiable, Equatable {
    let id: UUID
    var label: String
    var topicSuffix: String
    var actions: [ActionDraft]

    init(id: UUID = UUID(), label: String, topicSuffix: String = "", actions: [ActionDraft]) {
        self.id = id
        self.label = label
        self.topicSuffix = topicSuffix
        self.actions = actions
    }
}

extension Array where Element == ControlDraft {
    static func defaults() -> [ControlDraft] {
        [
            ControlDraft(label: "电源", topicSuffix: "", actions: [
                ActionDraft(label: "开", payload: "kai_1"),
                ActionDraft(label: "关", payload: "guan_1")
            ]),
            ControlDraft(label: "风扇", topicSuffix: "", actions: [
                ActionDraft(label: "开", payload: "kai_2"),
                ActionDraft(label: "关", payload: "guan_2")
            ])
        ]
    }

    static func from(config: MQTTConfig?) -> [ControlDraft] {
        guard let config else { return [] }
        let grouped = Dictionary(grouping: config.commands) { $0.groupKey ?? UUID().uuidString }
        return grouped
            .map { key, commands in
                let sorted = commands.sorted { $0.order < $1.order }
                let baseLabel = sorted.first?.groupLabel ?? key
                let firstTopic = sorted.first?.topic ?? ""
                let topicSuffix: String
                if firstTopic.hasPrefix(config.controlTopic) {
                    topicSuffix = String(firstTopic.dropFirst(config.controlTopic.count))
                } else {
                    topicSuffix = ""
                }
                return ControlDraft(label: baseLabel,
                                    topicSuffix: topicSuffix,
                                    actions: sorted.map { ActionDraft(label: $0.label, payload: $0.payload) })
            }
            .sorted { $0.label < $1.label }
    }
}

struct AddDeviceView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var mqtt: MQTTManager
    @Environment(\.dismiss) private var dismiss

    @State private var deviceIdentifier: String = "lamp01"
    @State private var name: String = "客厅灯"
    @State private var controlTopic: String = "devices/lamp01"
    @State private var stateTopic: String = ""
    @State private var controls: [ControlDraft] = .defaults()
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("基础") {
                    TextField("设备标识", text: $deviceIdentifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("显示名称", text: $name)
                    TextField("控制主题", text: $controlTopic)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("状态主题（可选）", text: $stateTopic)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("控制列表")) {
                    if controls.isEmpty {
                        ContentUnavailableView("还没有控制项", systemImage: "slider.horizontal.3")
                    }
                    ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                        ControlEditor(index: index,
                                      control: binding(for: control.id),
                                      removeControl: { controls.removeAll { $0.id == control.id } })
                            .padding(.vertical, 4)
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
                    Button("保存设备") { saveDevice() }
                        .disabled(!isSaveEnabled)
                }
            }
            .navigationTitle("添加设备")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<ControlDraft> {
        guard let index = controls.firstIndex(where: { $0.id == id }) else {
            return .constant(ControlDraft(label: "", actions: []))
        }
        return $controls[index]
    }

    private var isSaveEnabled: Bool {
        !controlTopic.trimmingCharacters(in: .whitespaces).isEmpty && controls.contains { control in
            control.actions.contains { !$0.payload.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    private func saveDevice() {
        validationMessage = nil
        guard isSaveEnabled else {
            validationMessage = "请填写控制主题并至少添加一个动作"
            return
        }

        let device = Device(name: name.isEmpty ? deviceIdentifier : name,
                            type: .custom,
                            stateCategory: .switchable,
                            controlChannel: .mqtt)

        let config = MQTTConfig(stateTopic: stateTopic.trimmingCharacters(in: .whitespaces).isEmpty ? nil : stateTopic,
                                controlTopic: controlTopic)
        context.insert(config)

        var orderCounter = 0
        for (index, control) in controls.enumerated() {
            let groupKey = "control_\(index)"
            let groupLabel = control.label.isEmpty ? "控制 \(index + 1)" : control.label
            let suffix = control.topicSuffix.trimmingCharacters(in: .whitespaces)
            let finalTopic = controlTopic + suffix
            for action in control.actions {
                let cleanedPayload = action.payload.trimmingCharacters(in: .whitespaces)
                let actionLabel = action.label.isEmpty ? "动作 \(orderCounter + 1)" : action.label
                guard !cleanedPayload.isEmpty else { continue }
                let command = MQTTCommand(label: actionLabel,
                                           payload: cleanedPayload,
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
            validationMessage = "每个控制项需要至少一个有效动作"
            context.delete(config)
            return
        }

        device.mqttConfig = config
        context.insert(device)
        do {
            try context.save()
            mqtt.resubscribeAllDevices()
            dismiss()
        } catch {
            validationMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct ControlEditor: View {
    let index: Int
    @Binding var control: ControlDraft
    let removeControl: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("控制 #\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { removeControl() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .opacity(index == 0 ? 0.4 : 1)
                .disabled(index == 0)
            }
            TextField("控制名称", text: $control.label)
            TextField("Topic 后缀", text: $control.topicSuffix)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.secondary)
            ForEach(Array(control.actions.enumerated()), id: \.element.id) { actionIndex, action in
                ActionEditor(index: actionIndex,
                             action: Binding(
                                get: { control.actions[actionIndex] },
                                set: { control.actions[actionIndex] = $0 }
                             ),
                             removeAction: {
                                 control.actions.removeAll { $0.id == action.id }
                             })
            }
            Button {
                control.actions.append(ActionDraft(label: "动作", payload: ""))
            } label: {
                Label("新增动作", systemImage: "plus")
            }
        }
        .padding(.vertical, 6)
    }
}

struct ActionEditor: View {
    let index: Int
    @Binding var action: ActionDraft
    let removeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("动作 #\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { removeAction() } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
            }
            TextField("动作名称", text: $action.label)
            TextField("MQTT Payload", text: $action.payload)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.leading, 8)
    }
}
