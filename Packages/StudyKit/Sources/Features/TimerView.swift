import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI
import Sync

/// Stránka Časovač (`TimerPage` na webu): kruh, ovládání, co se učíš a režim.
public struct TimerView: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @State private var zen = false
    @State private var tip = Int.random(in: 0..<TimerMode.breakTips.count)
    @State private var newSubject: SubjectDraft?
    @FocusState private var pageFocused: Bool

    /// Pevná velikost bez posouvání – jen pro náhledy (ImageRenderer nevykreslí ScrollView).
    private var snapshotSize: CGSize?

    public init() {}

    init(snapshotSize: CGSize) {
        self.snapshotSize = snapshotSize
    }

    public var body: some View {
        Group {
            if let snapshotSize {
                page(size: snapshotSize)
            } else {
                GeometryReader { proxy in
                    ScrollView { page(size: proxy.size) }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Časovač")
        .focusable()
        .focusEffectDisabled()
        .focused($pageFocused)
        .onAppear { pageFocused = true }
        .onKeyPress(.space) {
            // Mezerník jen mimo textová pole (jako na webu) – jinak by mezera v tématu spustila blok.
            guard !isEditingText, timer.state.status != .idle || !timer.state.subjectId.isEmpty else { return .ignored }
            timer.toggle()
            return .handled
        }
        .sheet(item: $newSubject) { draft in
            SubjectEditor(draft: draft) { id in timer.configure(TimerSetup(subjectId: id)) }
        }
    }

    private func page(size: CGSize) -> some View {
        let metrics = PageMetrics(width: size.width)
        // Na velkém monitoru jsou nastavení ve dvou sloupcích vedle kruhu, jinak v jednom.
        let sideColumns = zen ? 0 : metrics.size == .wide ? 2 : 1
        return VStack(alignment: .leading, spacing: 28) {
            if !zen { header }
            if store.sync.mode == .readOnly && store.isConnected {
                Banner("Režim jen pro čtení: bloky se uloží jen na tomto Macu. Na GitHub odejdou, až v Nastavení vypneš „Jen čtení“.", systemImage: "lock", tone: .warn)
            }
            HStack(alignment: .top, spacing: 40) {
                timerCard(ringSize: ringSize(size, metrics: metrics, sideColumns: sideColumns))
                if sideColumns == 2 {
                    VStack(alignment: .leading, spacing: 32) {
                        NextUpInline()
                        studyingSection
                        NoiseSection()
                    }
                    .frame(width: Self.sideWidth)
                    modeSection.frame(width: Self.sideWidth)
                } else if sideColumns == 1 {
                    VStack(alignment: .leading, spacing: 32) {
                        NextUpInline()
                        studyingSection
                        modeSection
                        NoiseSection()
                    }
                    .frame(width: 380)
                }
            }
        }
        .padding(.horizontal, metrics.padding)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let sideWidth: CGFloat = 400

    /// Píše se do textového pole (téma)? Pole v AppKitu edituje sdílený `NSTextView` okna.
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    /// Kruh roste s oknem: na notebooku ~480 bodů, na velkém monitoru až 760 (v zen režimu 900).
    private func ringSize(_ size: CGSize, metrics: PageMetrics, sideColumns: Int) -> CGFloat {
        let byHeight = min(zen ? 900 : 760, max(300, size.height * (zen ? 0.72 : 0.56)))
        let side: CGFloat = sideColumns == 2 ? 2 * (Self.sideWidth + 40) : sideColumns == 1 ? 420 : 0
        let byWidth = metrics.contentWidth - side - 48
        return max(260, min(byHeight, byWidth))
    }

    // MARK: - Hlavička

    private var header: some View {
        let now = store.nowMs
        let today = Stats.totalSec(Stats.inRange(store.document.alive(Session.self), from: store.clock.startOfDay(now), to: now + 1))
        let goal = store.document.settings.dailyGoalMin * 60
        return PageHeader("Časovač") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("DNES").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Palette.text3)
                DurationText(Format.duration(today), size: 24)
                if goal > 0 {
                    Text("ze \(Format.duration(goal))").font(Typo.body).foregroundStyle(Palette.text3)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("timer.today")
        }
    }

    // MARK: - Kruh a ovládání

    private func timerCard(ringSize: CGFloat) -> some View {
        let state = timer.state
        return VStack(spacing: 20) {
            TimerFace(size: ringSize)
            if state.status != .idle, !state.subjectId.isEmpty {
                let subject = store.document.record(Subject.self, id: state.subjectId)
                HStack(spacing: 8) {
                    Circle().fill(Palette.subject(subject?.color ?? "#9aa3ad")).frame(width: 8, height: 8)
                    Text(subject?.name ?? "Smazaný předmět").fontWeight(.medium)
                    if !state.topic.isEmpty { Text("/ \(state.topic)").foregroundStyle(Palette.text3) }
                }
                .font(.system(size: 14))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("timer.studying")
            }
            TimerControls(size: .large)
            if state.isStudying {
                Button { timer.addInterruption() } label: {
                    Label { Text("Vyrušení \(state.interruptions)").monospacedDigit() } icon: { Image(systemName: "bell.slash") }
                }
                .buttonStyle(.denik(.ghost, size: .small))
                .help("Zaznamenej, když tě něco vyruší")
                .accessibilityIdentifier("timer.interruption")
            }
            if state.phase != .work {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cup.and.saucer").foregroundStyle(Palette.breakColor)
                    Text(TimerMode.breakTips[(tip + state.round) % TimerMode.breakTips.count]).foregroundStyle(Palette.text2)
                }
                .font(Typo.body)
                .frame(maxWidth: 460)
            }
            if state.status == .idle {
                Text(state.subjectId.isEmpty ? "Nejdřív vyber předmět." : "Mezerník spustí i pozastaví.")
                    .font(Typo.small).foregroundStyle(Palette.text3)
            }
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 560)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
        .overlay(alignment: .topTrailing) {
            Button { zen.toggle() } label: {
                Image(systemName: zen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.denik(.ghost, size: .small))
            .help(zen ? "Ukončit zen režim" : "Zen režim")
            .accessibilityLabel(zen ? "Ukončit zen režim" : "Zen režim")
            .padding(10)
        }
    }

    // MARK: - Co se učíš

    private var studyingSection: some View {
        let state = timer.state
        let subjects = store.document.alive(Subject.self).filter { !$0.archived || $0.id == state.subjectId }
        let lockedSubject = state.status != .idle && state.phase == .work && state.status != .ready
        return PageSection("Co se učíš") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("Předmět", selection: Binding(
                        get: { state.subjectId },
                        set: { timer.configure(TimerSetup(subjectId: $0)) }
                    )) {
                        Text("Vyber předmět…").tag("")
                        ForEach(subjects) { s in Text(s.name).tag(s.id) }
                    }
                    .labelsHidden()
                    .disabled(lockedSubject)
                    .accessibilityIdentifier("timer.subject")
                    Button { newSubject = SubjectDraft(newIn: store.document) } label: { Image(systemName: "plus") }
                        .buttonStyle(.denik(.normal, size: .small))
                        .help("Nový předmět")
                        .accessibilityLabel("Nový předmět")
                        .disabled(lockedSubject || store.sync.mode == .readOnly)
                }
                TextField("Téma (např. derivace, kapitola 4…)", text: Binding(
                    get: { state.topic },
                    set: { timer.configure(TimerSetup(topic: $0)) }
                ))
                .textFieldStyle(.roundedBorder)
                .textInputSuggestions {
                    ForEach(topicSuggestions(subjectId: state.subjectId, typed: state.topic), id: \.self) { name in
                        Text(name).textInputCompletion(name)
                    }
                }
                .accessibilityIdentifier("timer.topic")
                Text("Téma se uloží k sezení – najdeš ho v historii.").font(Typo.small).foregroundStyle(Palette.text3)
            }
            .padding(.top, 4)
        }
    }

    /// Dřívější témata předmětu, nejnovější první.
    private func topicSuggestions(subjectId: String, typed: String) -> [String] {
        guard !subjectId.isEmpty else { return [] }
        let key = typed.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        let fromSessions = store.document.alive(Session.self)
            .filter { $0.subjectId == subjectId && !$0.topic.isEmpty }
            .sorted { $0.start > $1.start }
            .map(\.topic)
        let fromTopics = store.document.alive(Topic.self).filter { $0.subjectId == subjectId && !$0.mastered }.map(\.name)
        return (fromSessions + fromTopics)
            .filter { name in
                let lower = name.lowercased()
                return lower != key && (key.isEmpty || lower.contains(key)) && seen.insert(lower).inserted
            }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - Režim

    private var modeSection: some View {
        let state = timer.state
        let locked = state.status != .idle
        let settings = store.document.settings
        return PageSection("Režim", accessory: {
            if locked {
                Text("změníš po ukončení")
            } else if settings.defaultMode != state.modeId {
                Button("Nastavit jako výchozí") {
                    store.updateSettings { $0.defaultMode = state.modeId }
                }
                .buttonStyle(.denik(.ghost, size: .small))
                .disabled(store.sync.mode == .readOnly)
            }
        }) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(timer.modes) { mode in
                    ModeButton(mode: mode, selected: mode.id == state.modeId) {
                        timer.configure(TimerSetup(modeId: mode.id))
                    }
                    .disabled(locked)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Jeden režim v mřížce (`.mode` na webu).
private struct ModeButton: View {
    let mode: TimerMode
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(mode.name).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                }
                Text(mode.tagline).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.text3).lineLimit(2)
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            .background(selected || (hovering && isEnabled) ? Palette.panel2 : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Palette.text3 : hovering && isEnabled ? Palette.lineStrong : Palette.line))
            .opacity(!isEnabled && !selected ? 0.4 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("mode.\(mode.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Kruh s odpočtem; překresluje se jednou za sekundu, jen když časovač běží.
struct TimerFace: View {
    @Environment(TimerStore.self) private var timer
    let size: CGFloat

    var body: some View {
        let state = timer.state
        if state.status == .running, let start = state.segmentStart {
            // Tiky zarovnané na začátek úseku → sekundy přeskakují přesně.
            TimelineView(.periodic(from: Date(timeIntervalSince1970: Double(start) / 1000), by: 1)) { context in
                TimerRing(model: TimerRingModel(state: state, mode: timer.mode, now: Int(context.date.timeIntervalSince1970 * 1000)), size: size)
            }
        } else {
            TimerRing(model: TimerRingModel(state: state, mode: timer.mode, now: timer.currentTime()), size: size)
        }
    }
}

/// Dílky a stupnice kruhu (`.seg`, `.ring-label` na webu, viewBox 200 × 200).
private struct RingDial: View, Equatable {
    nonisolated let segments: [TimerRingModel.Segment]
    nonisolated let labels: [Int]
    nonisolated let fractions: [Double]
    nonisolated let tone: TimerRingModel.Tone

    private var activeColor: Color {
        switch tone {
        case .work, .idle: Palette.accent
        case .rest: Palette.breakColor
        case .paused: Palette.text3
        }
    }

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 200
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let n = segments.count
            let step = 360 / Double(n)
            let gap = min(1.6, step * 0.22)
            for (i, segment) in segments.enumerated() {
                let from = -90 + Double(i) * step + gap / 2
                let to = -90 + Double(i + 1) * step - gap / 2
                var path = Path()
                path.addArc(center: center, radius: 80 * scale, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                let color: Color = switch segment {
                case .off: Palette.lineStrong
                case .lit: activeColor
                case .now: activeColor.opacity(0.45)
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 9 * scale, lineCap: .butt))
            }
            for (minute, fraction) in zip(labels, fractions) {
                let a = (-90 + fraction * 360) * .pi / 180
                let point = CGPoint(x: center.x + 94 * scale * cos(a), y: center.y + 94 * scale * sin(a))
                context.draw(Text("\(minute)").font(.system(size: 7.5 * scale)).monospacedDigit().foregroundStyle(Palette.text3), at: point)
            }
        }
    }
}

/// Kreslený kruh (`.ring` na webu): ciferník a čas uprostřed.
struct TimerRing: View {
    let model: TimerRingModel
    let size: CGFloat

    var body: some View {
        ZStack {
            // Ciferník se mění nejvýš jednou za (půl)minutu – každou sekundu se překreslí jen čas uprostřed.
            RingDial(segments: model.segments, labels: model.labels.map(\.minute), fractions: model.labels.map(\.fraction), tone: model.tone)
                .equatable()
            VStack(spacing: size * 0.03) {
                Text(model.phaseLabel)
                    .font(.system(size: max(14, min(28, size * 0.047)), design: .serif).italic())
                    .foregroundStyle(model.tone == .work ? Palette.accent : model.tone == .rest ? Palette.breakColor : Palette.text3)
                Text(model.time)
                    .font(.system(size: size * (model.time.count > 5 ? 0.17 : 0.24), weight: .regular, design: .serif).monospacedDigit())
                    .kerning(-size * 0.004)
                    .foregroundStyle(model.tone == .paused ? Palette.text2 : Palette.text)
                    .contentTransition(.identity)
                    .accessibilityIdentifier("timer.time")
                VStack(spacing: 9) {
                    Text(model.modeName.uppercased())
                        .font(.system(size: max(11, min(16, size * 0.03)), weight: .semibold)).kerning(0.8)
                        .foregroundStyle(Palette.text3)
                    if let rounds = model.rounds {
                        HStack(spacing: 5) {
                            ForEach(0..<rounds.total, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(i < rounds.done ? Palette.accent : Palette.lineStrong)
                                    .frame(width: max(14, min(22, size * 0.039)), height: 3)
                            }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("Kolo \(rounds.done) z \(rounds.total)")
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timer.ring")
    }
}

/// Ovládání časovače podle stavu (`TimerControls` na webu).
public struct TimerControls: View {
    @Environment(TimerStore.self) private var timer
    let size: DenikButtonStyle.Size

    public init(size: DenikButtonStyle.Size = .regular) {
        self.size = size
    }

    public var body: some View {
        let state = timer.state
        let isWork = state.phase == .work
        HStack(spacing: 8) {
            switch state.status {
            case .idle:
                Button { timer.start() } label: { Label("Začít učení", systemImage: "play.fill") }
                    .buttonStyle(.denik(.primary, size: size))
                    .disabled(state.subjectId.isEmpty)
                    .accessibilityIdentifier("timer.start")
            case .ready:
                Button { timer.start() } label: {
                    Label(isWork ? "Další blok" : "Začít pauzu", systemImage: isWork ? "play.fill" : "cup.and.saucer")
                }
                .buttonStyle(.denik(isWork ? .primary : .rest, size: size))
                .accessibilityIdentifier("timer.start")
                if !isWork {
                    Button { timer.skip() } label: { Label("Bez pauzy", systemImage: "forward.end") }
                        .buttonStyle(.denik(.normal, size: size))
                        .accessibilityIdentifier("timer.skip")
                }
                Button("Ukončit") { timer.discard() }
                    .buttonStyle(.denik(.ghost, size: size))
                    .accessibilityIdentifier("timer.end")
            case .running, .paused:
                if state.status == .running {
                    Button { timer.pause() } label: { Label("Pozastavit", systemImage: "pause.fill") }
                        .buttonStyle(.denik(.normal, size: size))
                        .accessibilityIdentifier("timer.pause")
                } else {
                    Button { timer.resume() } label: { Label("Pokračovat", systemImage: "play.fill") }
                        .buttonStyle(.denik(isWork ? .primary : .rest, size: size))
                        .accessibilityIdentifier("timer.resume")
                }
                if isWork && timer.mode.kind != .stopwatch {
                    Button { timer.finishWork() } label: {
                        Label(timer.mode.kind == .flowtime ? "Na pauzu" : "Hotovo", systemImage: "cup.and.saucer")
                    }
                    .buttonStyle(.denik(.normal, size: size))
                    .help("Uložit blok a jít na pauzu")
                    .accessibilityIdentifier("timer.finish")
                }
                if isWork {
                    Button { timer.stop() } label: { Label("Ukončit", systemImage: "stop.fill") }
                        .buttonStyle(.denik(.ghost, size: size))
                        .help("Uložit a ukončit")
                        .accessibilityIdentifier("timer.stop")
                } else {
                    Button { timer.skip() } label: { Label("Přeskočit", systemImage: "forward.end") }
                        .buttonStyle(.denik(.ghost, size: size))
                        .accessibilityIdentifier("timer.skip")
                }
            }
        }
    }
}
