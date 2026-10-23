// Mac Android Subsystem - first run: get the Android image.
// Licensed under the GNU General Public License v3 or later.

import AppKit
import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings
    @State private var getFDroid = true
    @State private var alwaysReady = false

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 8) {
                Text(L10n.format("Set up %@", AppConfig.displayName))
                    .font(.largeTitle.weight(.semibold))
                Text("Android apps on your Mac: every Android app in its own window, with its own icon in Launchpad and the Dock.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(alignment: .leading, spacing: 10) {
                Bullet(symbol: "arrow.down.circle", text: L10n.text("Downloads Android 17 (LineageOS 24, no Google apps), about 1.5 GB."))
                Bullet(symbol: "bolt", text: L10n.text("Android runs in a lightweight virtual machine on Apple silicon, at close to native speed."))
                Bullet(symbol: "lock", text: L10n.text("Everything stays on this Mac. Android only talks to the Mac through 127.0.0.1."))
            }
            .frame(maxWidth: 520, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Install F-Droid, the free and open-source app store", isOn: $getFDroid)
                Toggle("Always ready: start with my Mac and keep Android running in the background", isOn: $alwaysReady)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: 520, alignment: .leading)

            HStack(spacing: 12) {
                Button("Use an Image File…") {
                    UserDefaults.standard.set(getFDroid, forKey: "installFDroidAfterSetup")
                    settings.alwaysReady = alwaysReady
                    if let url = FilePicker.pickImage() { subsystem.installImage(from: url) }
                }
                Button("Download Android") {
                    UserDefaults.standard.set(getFDroid, forKey: "installFDroidAfterSetup")
                    settings.alwaysReady = alwaysReady
                    subsystem.downloadImage()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)

            Link("What's in the image, and how to build your own", destination: AppConfig.guide("image"))
                .font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct Bullet: View {
        let symbol: String
        let text: String
        var body: some View {
            Label {
                Text(text)
            } icon: {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
            }
        }
    }
}
