import SwiftUI
import SwiftData

struct DeviceListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Device.name) private var devices: [Device]
    @State private var isPresentingAdd = false

    var body: some View {
        NavigationStack {
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
        }
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
