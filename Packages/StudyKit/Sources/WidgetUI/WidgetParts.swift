import SwiftUI
import WidgetData
import WidgetKit

// Části, ze kterých se skládají jednotlivé widgety.

/// Dnešek: odučený čas, cíl a postup.
struct TodaySummary: View {
    let s: WidgetSnapshot
    let m: WidgetMoment
    var size: CGFloat = 34

    var body: some View {
        Themed { t in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Caption("Dnes")
                    Spacer(minLength: 4)
                    if s.streak > 0 && !m.isStale {
                        Label("\(s.streak)", systemImage: "flame").labelStyle(.titleAndIcon)
                            .font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(t.text3)
                            .accessibilityLabel("série \(s.streak) \(WidgetFormat.plural(s.streak, "den", "dny", "dní"))")
                    }
                }
                BigDuration(sec: m.studiedSec, size: size).padding(.top, 2)
                Text(goalText).font(.system(size: 11.5)).foregroundStyle(m.goalSec > 0 && m.studiedSec >= m.goalSec ? t.rest : t.text3).lineLimit(1)
                if m.goalSec > 0 {
                    ProgressBar(value: m.fraction, color: m.studiedSec >= m.goalSec ? t.rest : t.accent).frame(height: 5).padding(.top, 4)
                }
            }
        }
    }

    private var goalText: String {
        guard m.goalSec > 0 else { return "bez denního cíle" }
        if m.studiedSec >= m.goalSec { return "cíl \(WidgetFormat.duration(m.goalSec)) splněn" }
        return "ze \(WidgetFormat.duration(m.goalSec)) · zbývá \(WidgetFormat.duration(m.goalSec - m.studiedSec))"
    }
}

/// Běžící blok nebo pauza s ovládáním.
struct TimerPanel: View {
    let s: WidgetSnapshot
    let m: WidgetMoment
    var clockSize: CGFloat = 38
    var compactButtons = false

    var body: some View {
        Themed { t in
            let timer = m.timer
            let subject = s.subject(timer.subjectId)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if timer.isWork {
                        SubjectMark(color: subject.color)
                        Text(subject.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text).lineLimit(1)
                    } else {
                        Image(systemName: "cup.and.saucer").font(.system(size: 10, weight: .semibold)).foregroundStyle(t.rest)
                        Text("Pauza").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.rest)
                    }
                    Spacer(minLength: 0)
                }
                Text(subtitle(timer)).font(.system(size: 11)).foregroundStyle(t.text3).lineLimit(1)
                LiveClock(timer: timer, at: m.at, size: clockSize).padding(.top, 2)
                if !timer.countsUp {
                    ProgressBar(value: timer.progress(at: m.at), color: timer.isWork ? t.subject(subject.color) : t.rest).frame(height: 4)
                }
                controls(timer).padding(.top, 6)
            }
        }
    }

    private func subtitle(_ timer: WidgetSnapshot.TimerInfo) -> String {
        if m.phaseOver { return timer.isWork ? "blok doběhl – otevři aplikaci" : "pauza skončila" }
        let state = timer.status == .paused ? "pozastaveno" : timer.status == .ready ? (timer.isWork ? "další blok čeká" : "pauza čeká") : nil
        return [state, timer.isWork && !timer.topic.isEmpty ? timer.topic : nil, timer.modeName.isEmpty ? nil : timer.modeName]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func controls(_ timer: WidgetSnapshot.TimerInfo) -> some View {
        HStack(spacing: 6) {
            switch timer.status {
            case .running where timer.isWork:
                CommandButton(command: .button(.pause), title: "Pauza", symbol: "pause.fill", iconOnly: compactButtons)
                CommandButton(command: .button(.finish), title: "Hotovo", symbol: "checkmark", prominent: true, iconOnly: compactButtons)
            case .running:
                CommandButton(command: .button(.next), title: "Další blok", symbol: "forward.fill", prominent: true, iconOnly: compactButtons)
                CommandButton(command: .button(.stop), title: "Konec", symbol: "stop.fill", iconOnly: compactButtons)
            case .paused:
                CommandButton(command: .button(.resume), title: "Pokračovat", symbol: "play.fill", prominent: true, iconOnly: compactButtons)
                CommandButton(command: .button(.stop), title: "Konec", symbol: "stop.fill", iconOnly: compactButtons)
            case .ready, .idle:
                CommandButton(command: .button(.next), title: timer.isWork ? "Další blok" : "Pauza", symbol: timer.isWork ? "play.fill" : "cup.and.saucer",
                              prominent: true, iconOnly: compactButtons)
                CommandButton(command: .button(.stop), title: "Konec", symbol: "stop.fill", iconOnly: compactButtons)
            }
        }
    }
}

/// „Co teď?“ s tlačítkem, které blok rovnou spustí.
struct NextUpPanel: View {
    let s: WidgetSnapshot
    var titleSize: CGFloat = 15
    var titleLines = 2
    var showsReason = true

    var body: some View {
        Themed { t in
            if let top = s.nextUp.first {
                let subject = s.subject(top.subjectId)
                VStack(alignment: .leading, spacing: 4) {
                    Caption("Co teď?")
                    HStack(spacing: 6) {
                        SubjectMark(color: subject.color)
                        Text(subject.name).font(.system(size: 11.5)).foregroundStyle(t.text2).lineLimit(1)
                    }
                    .padding(.top, 2)
                    Text(top.title).font(.system(size: titleSize, design: .serif)).foregroundStyle(t.text)
                        .lineLimit(titleLines).fixedSize(horizontal: false, vertical: true)
                    if showsReason && !top.reason.isEmpty {
                        Text(top.reason).font(.system(size: 11)).foregroundStyle(t.text3).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    CommandButton(command: .button(.start, subjectId: top.subjectId, topic: top.topic, modeId: top.modeId),
                                  title: "Začít · \(top.minutes) min", symbol: "play.fill", prominent: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Co teď?")
                    Text("Zatím není co doporučit – přidej předměty, cíle nebo zkoušky.")
                        .font(.system(size: 11.5)).foregroundStyle(t.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Řádek plánu: čas, barva předmětu, název a stav.
struct PlanLine: View {
    let block: WidgetSnapshot.Block
    let s: WidgetSnapshot
    let m: WidgetMoment
    /// Úzký sloupec: jen čas a předmět.
    var compact = false

    var body: some View {
        Themed { t in
            let subject = s.subject(block.subjectId)
            let isNow = m.current?.id == block.id
            HStack(spacing: 8) {
                Text(WidgetFormat.time(block.start))
                    .font(.system(size: 12.5, design: .serif).monospacedDigit())
                    .foregroundStyle(block.done ? t.text3 : t.text)
                    .frame(width: 38, alignment: .leading)
                RoundedRectangle(cornerRadius: 1.5).fill(t.subject(subject.color)).frame(width: 3).frame(maxHeight: 24)
                    .opacity(block.done ? 0.45 : 1).widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text(subject.name).font(.system(size: 12, weight: .medium)).foregroundStyle(block.done ? t.text3 : t.text)
                        .strikethrough(block.done, color: t.text3)
                    if !block.title.isEmpty {
                        Text(block.title).font(.system(size: 10.5)).foregroundStyle(t.text3)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if compact {
                    EmptyView()
                } else if block.done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(t.rest)
                } else if isNow {
                    Text("teď").font(.system(size: 10, weight: .bold)).foregroundStyle(t.accent).widgetAccentable()
                } else {
                    Text("\((block.end - block.start) / 60_000) min").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(t.text3)
                }
            }
            .frame(minHeight: 26)
        }
    }
}

/// Bloky dne od toho, který běží nebo přijde, s rezervou na hotové před ním.
enum PlanWindow {
    static func rows(_ plan: [WidgetSnapshot.Block], m: WidgetMoment, limit: Int) -> [WidgetSnapshot.Block] {
        guard plan.count > limit else { return plan }
        let anchor = plan.firstIndex { !$0.done && $0.end > m.at } ?? max(0, plan.count - limit)
        let start = max(0, min(anchor - (anchor > 0 ? 1 : 0), plan.count - limit))
        return Array(plan[start..<start + limit])
    }
}

/// Seznam plánu se záhlavím.
struct PlanList: View {
    let s: WidgetSnapshot
    let m: WidgetMoment
    let limit: Int
    var caption = "Plán · dnes"

    var body: some View {
        Themed { t in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Caption(caption)
                    Spacer()
                    if !m.plan.isEmpty {
                        let done = m.plan.filter(\.done).count
                        let total = m.plan.reduce(0) { $0 + ($1.end - $1.start) / 1000 }
                        Text("\(done)/\(m.plan.count) · \(WidgetFormat.duration(total))").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(t.text3)
                    }
                }
                .padding(.bottom, 4)
                if m.plan.isEmpty {
                    Text("Na dnešek nic v plánu.").font(.system(size: 12)).foregroundStyle(t.text2)
                    Text("Ranní plán v aplikaci navrhne bloky do denního cíle.").font(.system(size: 11)).foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(PlanWindow.rows(m.plan, m: m, limit: limit)) { PlanLine(block: $0, s: s, m: m) }
                    if m.plan.count > limit {
                        Text("+ \(m.plan.count - limit) další").font(.system(size: 10.5)).foregroundStyle(t.text3).padding(.top, 2)
                    }
                }
            }
        }
    }
}

/// Řádek zkoušky: počet dní, název, předmět a datum.
struct ExamLine: View {
    let exam: WidgetSnapshot.ExamItem
    let daysLeft: Int
    let s: WidgetSnapshot

    var body: some View {
        Themed { t in
            let subject = s.subject(exam.subjectId)
            HStack(spacing: 10) {
                VStack(spacing: -2) {
                    Text("\(daysLeft)").font(.system(size: 20, design: .serif).monospacedDigit()).foregroundStyle(daysLeft <= 3 ? t.warn : t.text)
                    Text(WidgetFormat.plural(daysLeft, "den", "dny", "dní")).font(.system(size: 9.5)).foregroundStyle(t.text3)
                }
                .frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(exam.name).font(.system(size: 12, weight: .medium)).foregroundStyle(t.text).lineLimit(1)
                    HStack(spacing: 5) {
                        SubjectMark(color: subject.color, size: 6)
                        Text(subject.name + " · " + WidgetFormat.day(exam.day) + (exam.time.isEmpty ? "" : " · \(exam.time)"))
                            .font(.system(size: 10.5)).foregroundStyle(t.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Týden po dnech: sloupky odučeného času, dnešek zvýrazněný.
struct WeekBars: View {
    let m: WidgetMoment

    var body: some View {
        Themed { t in
            let top = max(1, m.week.max() ?? 1)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<7, id: \.self) { i in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i == m.todayIndex ? t.accent : t.text3.opacity(0.55))
                            .frame(height: max(2, 36 * CGFloat(m.week[i]) / CGFloat(top)))
                            .widgetAccentable(i == m.todayIndex)
                        Text(WidgetFormat.weekdaysShort[i]).font(.system(size: 9, weight: i == m.todayIndex ? .bold : .regular))
                            .foregroundStyle(i == m.todayIndex ? t.text : t.text3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 50, alignment: .bottom)
        }
    }
}

/// Bez souhrnu: aplikace ještě nikdy neběžela nebo data nejsou připojená.
struct NoData: View {
    var body: some View {
        Themed { t in
            VStack(alignment: .leading, spacing: 6) {
                Caption("Study Tracker")
                Spacer()
                Text("Otevři Study Tracker").font(.system(size: 15, design: .serif)).foregroundStyle(t.text)
                Text("Widget se naplní daty po prvním spuštění aplikace.").font(.system(size: 11)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
