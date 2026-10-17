import SwiftUI

/// The menu bar panel: devices with their batteries, then lighting and the
/// screen, each a heading and a couple of controls, the way Control Center does it.
struct Panel: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Section("Devices") {
                DeviceRow(symbol: "keyboard", name: "BlackWidow V4 Pro 75%",
                          connected: model.keyboard, battery: model.keyboardBattery)
                DeviceRow(symbol: "computermouse", name: "Basilisk V3 Pro",
                          connected: model.mouse, battery: model.mouseBattery)
            }

            Section("Lighting") {
                HStack {
                    Label("Keyboard and mouse", systemImage: "lightbulb")
                    Spacer()
                    Toggle("Keyboard and mouse", isOn: $model.lightsOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                BrightnessSlider(value: $model.lightBrightness)
                    .disabled(!model.lightsOn)
            }

            Section("Screen") {
                Picker(selection: $model.mode) {
                    ForEach(OledController.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Label("Shows", systemImage: "rectangle.on.rectangle")
                }
                .pickerStyle(.menu)
                BrightnessSlider(value: $model.screenBrightness)
                Label(model.screen, systemImage: model.screen == "Clock" ? "clock" : "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.uploadBootAnimation()
                } label: {
                    Label(model.uploading ? "Uploading Boot Animation…" : "Upload Boot Animation",
                          systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.plain)
                .disabled(model.uploading || !model.keyboard)
                if let message = model.message, !model.uploading {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Toggle("Start at Login", isOn: Binding(get: { model.startAtLogin },
                                                           set: { model.setStartAtLogin($0) }))
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("Quit") { model.quit() }
                        .keyboardShortcut("q")
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refreshBatteries() }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct DeviceRow: View {
    let symbol: String
    let name: String
    let connected: Bool
    let battery: Model.Battery?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(connected ? .primary : .tertiary)
            Text(name)
                .foregroundStyle(connected ? .primary : .secondary)
            Spacer()
            if !connected {
                Text("Not connected").font(.caption).foregroundStyle(.secondary)
            } else if let battery {
                HStack(spacing: 4) {
                    Text("\(battery.percent)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: Self.symbol(for: battery))
                        .foregroundStyle(battery.percent <= 20 && !battery.charging ? .red : .secondary)
                }
                .font(.callout)
            }
        }
    }

    static func symbol(for battery: Model.Battery) -> String {
        if battery.charging { return "battery.100percent.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct BrightnessSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min").foregroundStyle(.secondary)
            Slider(value: $value, in: 0.05...1)
                .controlSize(.small)
            Image(systemName: "sun.max").foregroundStyle(.secondary)
        }
    }
}
