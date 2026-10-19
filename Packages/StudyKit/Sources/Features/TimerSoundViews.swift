import AppModel
import Core
import DesignSystem
import SwiftUI
import Sync

private let noiseLabels: [NoiseType: String] = [.off: "Vypnuto", .brown: "Hnědý", .pink: "Růžový", .white: "Bílý"]

/// Šum na soustředění (`NoiseControl` na webu): hraje sám jen během bloku učení.
struct NoiseSection: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    /// Hlasitost během tažení posuvníkem – uloží se až po puštění.
    @State private var dragging: Double?
    @State private var previewing = false

    var body: some View {
        let settings = store.document.settings
        let active = timer.state.status == .running && timer.state.phase == .work
        let editable = store.sync.mode == .readWrite || !store.isConnected
        PageSection("Šum na soustředění") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Šum", selection: Binding(
                    get: { settings.noiseType },
                    set: { type in
                        store.updateSettings { $0.noiseType = type }
                        timer.syncEffects()
                    }
                )) {
                    ForEach(NoiseType.allCases, id: \.self) { Text(noiseLabels[$0] ?? "").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("noise.type")
                if settings.noiseType != .off {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill").foregroundStyle(Palette.text3)
                        Slider(
                            value: Binding(get: { dragging ?? settings.noiseVolume }, set: { dragging = $0 }),
                            in: 0.05...1
                        ) { editing in
                            guard !editing, let value = dragging else { return }
                            dragging = nil
                            store.updateSettings { $0.noiseVolume = (value * 20).rounded() / 20 }
                            timer.syncEffects()
                        }
                        .accessibilityLabel("Hlasitost šumu")
                        .accessibilityIdentifier("noise.volume")
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(Palette.text3)
                        if !active {
                            Button(previewing ? "Hraje…" : "Vyzkoušet") {
                                timer.previewNoise()
                                previewing = true
                            }
                            .buttonStyle(.study(.normal, size: .small))
                            .disabled(previewing)
                            .task(id: previewing) {
                                guard previewing else { return }
                                try? await Task.sleep(for: .seconds(5))
                                previewing = false
                            }
                            .accessibilityIdentifier("noise.preview")
                        }
                    }
                }
                Text("Hraje automaticky jen během bloku učení. Hnědý je nejhlubší a nejméně rušivý.")
                    .font(Typo.small).foregroundStyle(Palette.text3)
            }
            .padding(.top, 4)
            .disabled(!editable)
        }
    }
}

/// Zvuk a upozornění časovače v Nastavení (část „Časovač“ na webu).
public struct TimerSoundSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @State private var dragging: Double?

    public init() {}

    public var body: some View {
        let settings = store.document.settings
        let editable = store.sync.mode == .readWrite || !store.isConnected
        PageSection("Časovač") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(get: { settings.sound }, set: { v in store.updateSettings { $0.sound = v } })) {
                    settingLabel("Zvonek na konci bloku a pauzy", "Jemná zvonkohra, vygenerovaná v aplikaci.")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("settings.sound")
                if settings.sound {
                    HStack(spacing: 12) {
                        Text("Hlasitost").foregroundStyle(Palette.text2)
                        Slider(value: Binding(get: { dragging ?? settings.volume }, set: { dragging = $0 }), in: 0...1) { editing in
                            guard !editing, let value = dragging else { return }
                            dragging = nil
                            store.updateSettings { $0.volume = (value * 20).rounded() / 20 }
                        }
                        .frame(maxWidth: 260)
                        .accessibilityLabel("Hlasitost zvonku")
                        Button { timer.effects?.previewChime(volume: dragging ?? settings.volume) } label: { Image(systemName: "speaker.wave.2") }
                            .buttonStyle(.study(.ghost, size: .small))
                            .help("Přehrát ukázku")
                            .accessibilityLabel("Přehrát ukázku")
                    }
                    .padding(.leading, 2)
                }
                Toggle(isOn: Binding(get: { settings.notifications }, set: { v in
                    store.updateSettings { $0.notifications = v }
                    timer.syncEffects()
                })) {
                    settingLabel("Systémové notifikace", "Upozornění na konec bloku, když je aplikace na pozadí. macOS se při prvním bloku zeptá na povolení.")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("settings.notifications")
            }
            .frame(maxWidth: 720, alignment: .leading)
            .disabled(!editable)
        }
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(Typo.small).foregroundStyle(Palette.text3)
        }
    }
}
