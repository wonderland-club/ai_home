import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            DeviceListView()
                .tabItem { Label("设备", systemImage: "switch.2") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
