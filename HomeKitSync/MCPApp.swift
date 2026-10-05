import HomeKit
import SwiftUI

@main
struct HomeKitMCPApp: App {
    @StateObject private var server = AppWrapper()

    var body: some Scene {
        WindowGroup {
            ContentView(server: server)
                .frame(minWidth: 420, minHeight: 320)
        }
    }
}

struct ContentView: View {
    @ObservedObject var server: AppWrapper

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HomeKit MCP Server")
                .font(.title)
                .bold()

            Text("Listening on http://127.0.0.1:\(String(server.port))/mcp (loopback only)")
                .font(.body)

            Text("Organisation tools only: no accessory control.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Tools")
                .font(.headline)
                .padding(.top, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(server.toolNames, id: \.self) { name in
                        Text("• \(name)")
                    }
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Quit") { exit(0) }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

final class AppWrapper: ObservableObject {
    private let httpServer = HTTPMCPServer()

    var port: UInt16 { httpServer.port }
    var toolNames: [String] { ToolCatalog.tools.compactMap { $0["name"] as? String } }
}
