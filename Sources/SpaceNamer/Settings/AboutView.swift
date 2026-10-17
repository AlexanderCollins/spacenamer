import AppKit
import SwiftUI

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("SpaceNamer")
                .font(.title.weight(.semibold))
            Text(version)
                .foregroundStyle(.secondary)
            Text("Name your Spaces and jump between them instantly.\nRuns locally, keeps System Integrity Protection on.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/AlexanderCollins/spacenamer", destination: URL(string: "https://github.com/AlexanderCollins/spacenamer")!)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(width: 560, height: 340)
    }
}
