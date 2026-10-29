import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI
import Sync

/// Stránka Časovač: kruh s odpočtem a ovládáním uprostřed, vpravo co se učíš, režim a šum.
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
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                header
                if store.sync.mode == .readOnly && store.isConnected {
                    Banner("Režim jen pro čtení: bloky se uloží jen na tomto Macu. Na GitHub odejdou, až v Nastavení vypneš „Jen čtení“.", systemImage: "lock", tone: .warn)
                }
                stage(ringSize: ringSize(size, metrics: metrics, sideColumns: sideColumns))
            }
            .padding(.leading, metrics.size == .compact ? metrics.padding : 64)
            .padding(.trailing, metrics.size == .compact ? metrics.padding : 48)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            if sideColumns > 0 {
                Group {
                    if sideColumns == 2 {
                        HStack(alignment: .top, spacing: 40) {
                            VStack(alignment: .leading, spacing: 34) {
                                NextUpInline()
                                studyingSection
                                NoiseSection()
                            }
                            modeSection
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 34) {
                            NextUpInline()
                            studyingSection
                            modeSection
                            NoiseSection()
                        }
                    }
                }
                .padding(.horizontal, metrics.size == .wide ? 44 : 32)
                .padding(.top, 60)
                .padding(.bottom, 40)
                .frame(width: sideColumns == 2 ? 2 * Self.sideWidth + 40 + 88 : 380, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: size.height, alignment: .topLeading)
    }

    private static let sideWidth: CGFloat = 360

    /// Píše se do textového pole (téma)? Pole v AppKitu edituje sdílený `NSTextView` okna.
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    /// Kruh roste s oknem: na notebooku ~480 bodů, na velkém monitoru až 760 (v zen režimu 900).
    private func ringSize(_ size: CGSize, metrics: PageMetrics, sideColumns: Int) -> CGFloat {
        let byHeight = min(zen ? 900 : 760, max(300, size.height * (zen ? 0.72 : 0.56)))
        let side: CGFloat = sideColumns == 2 ? 2 * Self.sideWidth + 40 + 88 : sideColumns == 1 ? 380 : 0
        let byWidth = size.width - side - 160
        return max(260, min(byHeight, byWidth))
    }

    // MARK: - Hlavička

    private var header: some View {
        let now = store.nowMs
        let today = Stats.totalSec(Stats.inRange(store.document.alive(Session.self), from: store.clock.startOfDay(now), to: now + 1))
        let goal = store.document.settings.dailyGoalMin * 60
        let subtitle = "Dnes \(Format.duration(today))" + (goal > 0 ? " ze \(Format.duration(goal))" : "") + " · \(timer.mode.name)"
        return PageHeader("Časovač", subtitle: subtitle, glyph: .timer) {
            Button { withAnimation(.easeOut(duration: 0.2)) { zen.toggle() } } label: {
                Label(zen ? "Ukončit zen" : "Zen", systemImage: zen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.study(.ghost, size: .small))
            .help(zen ? "Ukončit zen režim" : "Zen režim – jen kruh, bez nastavení")
        }
    }

    // MARK: - Kruh a ovládání

    private func stage(ringSize: CGFloat) -> some View {
        let state = timer.state
        return VStack(spacing: 22) {
            TimerFace(size: ringSize)
            if state.status != .idle, !state.subjectId.isEmpty {
                let subject = store.document.record(Subject.self, id: state.subjectId)
                HStack(spacing: 8) {
                    Text(state.topic.isEmpty ? subject?.name ?? "Smazaný předmět" : state.topic).font(.system(size: 15, weight: .semibold))
                    SubjectCapsule(name: subject?.name ?? "Smazaný předmět", color: subject?.color ?? "#9aa3ad")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("timer.studying")
            }
            TimerControls(size: .large)
            if state.isStudying {
                Button { timer.addInterruption() } label: {
                    Label { Text("Vyrušení \(state.interruptions)").monospacedDigit() } icon: { Image(systemName: "bell.slash") }
                }
                .buttonStyle(.study(.ghost, size: .small))
                .help("Zaznamenej, když tě něco vyruší")
                .accessibilityIdentifier("timer.interruption")
            }
            if state.status != .idle { FocusTimerNote() }
            if state.phase != .work {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cup.and.saucer").foregroundStyle(Palette.breakColor)
                    Text(TimerMode.breakTips[(tip + state.round) % TimerMode.breakTips.count]).foregroundStyle(Palette.text2)
                }
                .font(Typo.body)
                .frame(maxWidth: 460)
            }
            if state.status == .idle {
                Text(state.subjectId.isEmpty ? "Nejdřív vpravo vyber předmět." : "Mezerník spustí i pozastaví.")
                    .font(Typo.small).foregroundStyle(Palette.text3)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
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
                        .buttonStyle(.study(.normal, size: .small))
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
                .buttonStyle(.study(.ghost, size: .small))
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

/// Jeden režim v mřížce: vybraný modře, ostatní při najetí jemně podbarvené.
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
            .foregroundStyle(selected ? Palette.accent : Palette.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            .background(selected ? Palette.accentSoft : hovering && isEnabled ? Palette.panel2 : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(!isEnabled && !selected ? 0.4 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

/// Kolej a oblouk kruhu. Překreslí se, jen když se oblouk viditelně posune (po ~1/360 obvodu).
private struct RingArc: View, Equatable {
    nonisolated let step: Int
    nonisolated let tone: TimerRingModel.Tone

    private var color: Color {
        switch tone {
        case .work, .idle: Palette.accent
        case .rest: Palette.breakColor
        case .paused: Palette.text3
        }
    }

    var body: some View {
        GeometryReader { geo in
            let line = max(6, geo.size.width * 0.022)
            ZStack {
                Circle().stroke(Palette.panel2, lineWidth: line)
                Circle()
                    .trim(from: 0, to: Double(step) / 360)
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(line / 2)
        }
    }
}

/// Kruh časovače: oblouk postupu, nad časem fáze, pod ním režim a kola.
struct TimerRing: View {
    let model: TimerRingModel
    let size: CGFloat

    var body: some View {
        ZStack {
            RingArc(step: Int((min(1, max(0, model.progress)) * 360).rounded()), tone: model.tone)
                .equatable()
            VStack(spacing: size * 0.025) {
                Text(model.phaseLabel)
                    .font(.system(size: max(13, min(20, size * 0.036)), weight: .semibold))
                    .foregroundStyle(model.tone == .work ? Palette.accent : model.tone == .rest ? Palette.breakColor : Palette.text3)
                Text(model.time)
                    .font(.system(size: size * (model.time.count > 5 ? 0.16 : 0.22), weight: .light).monospacedDigit())
                    .kerning(-size * 0.003)
                    .foregroundStyle(model.tone == .paused ? Palette.text2 : Palette.text)
                    .contentTransition(.identity)
                    .accessibilityIdentifier("timer.time")
                VStack(spacing: 10) {
                    Text(model.modeName)
                        .font(.system(size: max(12, min(15, size * 0.028)), weight: .medium))
                        .foregroundStyle(Palette.text3)
                    if let rounds = model.rounds {
                        HStack(spacing: 6) {
                            ForEach(0..<rounds.total, id: \.self) { i in
                                Circle()
                                    .fill(i < rounds.done ? Palette.accent : Palette.panel3)
                                    .frame(width: 7, height: 7)
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
    let size: StudyButtonStyle.Size

    public init(size: StudyButtonStyle.Size = .regular) {
        self.size = size
    }

    public var body: some View {
        let state = timer.state
        let isWork = state.phase == .work
        HStack(spacing: 8) {
            switch state.status {
            case .idle:
                Button { timer.start() } label: { Label("Začít učení", systemImage: "play.fill") }
                    .buttonStyle(.study(.primary, size: size))
                    .disabled(state.subjectId.isEmpty)
                    .accessibilityIdentifier("timer.start")
            case .ready:
                Button { timer.start() } label: {
                    Label(isWork ? "Další blok" : "Začít pauzu", systemImage: isWork ? "play.fill" : "cup.and.saucer")
                }
                .buttonStyle(.study(isWork ? .primary : .rest, size: size))
                .accessibilityIdentifier("timer.start")
                if !isWork {
                    Button { timer.skip() } label: { Label("Bez pauzy", systemImage: "forward.end") }
                        .buttonStyle(.study(.normal, size: size))
                        .accessibilityIdentifier("timer.skip")
                }
                Button("Ukončit") { timer.discard() }
                    .buttonStyle(.study(.ghost, size: size))
                    .accessibilityIdentifier("timer.end")
            case .running, .paused:
                if state.status == .running {
                    Button { timer.pause() } label: { Label("Pozastavit", systemImage: "pause.fill") }
                        .buttonStyle(.study(.normal, size: size))
                        .accessibilityIdentifier("timer.pause")
                } else {
                    Button { timer.resume() } label: { Label("Pokračovat", systemImage: "play.fill") }
                        .buttonStyle(.study(isWork ? .primary : .rest, size: size))
                        .accessibilityIdentifier("timer.resume")
                }
                if isWork && timer.mode.kind != .stopwatch {
                    Button { timer.finishWork() } label: {
                        Label(timer.mode.kind == .flowtime ? "Na pauzu" : "Hotovo", systemImage: "cup.and.saucer")
                    }
                    .buttonStyle(.study(.normal, size: size))
                    .help("Uložit blok a jít na pauzu")
                    .accessibilityIdentifier("timer.finish")
                }
                if isWork {
                    Button { timer.stop() } label: { Label("Ukončit", systemImage: "stop.fill") }
                        .buttonStyle(.study(.ghost, size: size))
                        .help("Uložit a ukončit")
                        .accessibilityIdentifier("timer.stop")
                } else {
                    Button { timer.skip() } label: { Label("Přeskočit", systemImage: "forward.end") }
                        .buttonStyle(.study(.ghost, size: size))
                        .accessibilityIdentifier("timer.skip")
                }
            }
        }
    }
}

/// Pod časovačem: co Soustředění během bloku blokuje (jen když něco).
private struct FocusTimerNote: View {
    @Environment(FocusController.self) private var focus: FocusController?

    var body: some View {
        if let focus {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let now = Int(context.date.timeIntervalSince1970 * 1000)
                let state = focus.state(at: now)
                if !state.rules.isEmpty {
                    Label {
                        Text("Blokuje: \(FocusText.names(state)) · \(FocusText.until(state.rules.compactMap(\.until).max()) ?? "do konce bloku")")
                    } icon: {
                        Image(systemName: state.isLocked ? "lock.fill" : "moon.circle")
                    }
                    .font(Typo.small)
                    .foregroundStyle(Palette.text3)
                    .accessibilityIdentifier("timer.focus")
                }
            }
        }
    }
}
