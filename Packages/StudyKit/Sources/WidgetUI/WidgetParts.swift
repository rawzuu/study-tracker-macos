import SwiftUI
import WidgetData
import WidgetKit

// Části, ze kterých se skládají jednotlivé widgety. Všechny drží stejný rytmus: popisek sekce,
// hlavní údaj, doplňující řádek; tlačítka a patičky sedí u spodního okraje, aby sloupce vedle sebe
// končily na stejné lince.

/// Série dní s učením (plamínek a počet).
struct StreakBadge: View {
    let days: Int

    var body: some View {
        Themed { t in
            HStack(spacing: 3) {
                Image(systemName: "flame.fill").font(.system(size: 9.5))
                Text("\(days)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(t.text3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("série \(days) \(WidgetFormat.plural(days, "den", "dny", "dní"))")
        }
    }
}

/// Dnešek: odučený čas, postup k cíli a kolik zbývá.
struct TodaySummary: View {
    let s: WidgetSnapshot
    let m: WidgetMoment
    var size: CGFloat = 34

    var body: some View {
        Themed { t in
            let met = m.goalSec > 0 && m.studiedSec >= m.goalSec
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    DayGlyph(day: Calendar.current.component(.day, from: WidgetFormat.date(m.day)))
                    Caption("Dnes")
                    Spacer(minLength: 4)
                    if s.streak > 0 && !m.isStale { StreakBadge(days: s.streak) }
                }
                BigDuration(sec: m.studiedSec, size: size).padding(.top, 5)
                if m.goalSec > 0 {
                    ProgressBar(value: m.fraction, color: met ? t.rest : t.accent).frame(height: 5).padding(.top, 7)
                }
                Text(goalText(met: met)).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(met ? t.rest : t.text3).lineLimit(1).minimumScaleFactor(0.85).padding(.top, 6)
            }
        }
    }

    private func goalText(met: Bool) -> String {
        guard m.goalSec > 0 else { return "bez denního cíle" }
        if met { return "cíl \(WidgetFormat.duration(m.goalSec)) splněn" }
        return "ze \(WidgetFormat.duration(m.goalSec)) · zbývá \(WidgetFormat.duration(m.goalSec - m.studiedSec))"
    }
}

/// Patička: blok plánu, který běží teď, nebo další; po posledním „plán hotový“.
struct NextLine: View {
    let s: WidgetSnapshot
    let m: WidgetMoment

    var body: some View {
        Themed { t in
            if let b = m.current ?? m.next {
                let subject = s.subject(b.subjectId)
                let isNow = m.current?.id == b.id
                VStack(alignment: .leading, spacing: 3) {
                    Caption(isNow ? "Teď v plánu" : "Další · \(WidgetFormat.time(b.start))", color: isNow ? t.accent : t.text3)
                    HStack(spacing: 6) {
                        SubjectMark(color: subject.color, size: 7)
                        Text(subject.name).font(.system(size: 12, weight: .medium)).foregroundStyle(t.text).layoutPriority(1)
                        if !b.title.isEmpty {
                            Text(b.title).font(.system(size: 11)).foregroundStyle(t.text3)
                        }
                    }
                    .lineLimit(1)
                }
            } else if !m.plan.isEmpty {
                Label("Plán na dnes hotový", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(t.rest).lineLimit(1)
            }
        }
    }
}

/// Běžící blok, pauza nebo blok, který čeká – s hlavním tlačítkem a kruhovým vedlejším.
struct TimerPanel: View {
    let s: WidgetSnapshot
    let m: WidgetMoment
    var clockSize: CGFloat = 38
    /// Roztáhnout na celou výšku (hodiny a tlačítka u spodního okraje); jinak těsně pod sebou.
    var fills = true

    var body: some View {
        Themed { t in
            let timer = m.timer
            let subject = s.subject(timer.subjectId)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if timer.isWork {
                        SubjectMark(color: subject.color)
                        Text(subject.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text)
                    } else {
                        Image(systemName: "cup.and.saucer.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(t.rest)
                        Text("Pauza").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.rest)
                    }
                }
                .lineLimit(1)
                // Bez tří teček: když se celý řádek nevejde, vypadne nejdřív režim, pak téma.
                ViewThatFits(in: .horizontal) {
                    ForEach(subtitles(timer), id: \.self) { Text($0).fixedSize() }
                }
                .font(.system(size: 11)).foregroundStyle(timer.status == .paused ? t.text2 : t.text3)
                .frame(maxWidth: .infinity, alignment: .leading).clipped()
                .padding(.top, 3)
                if fills {
                    Spacer(minLength: 4)
                } else {
                    Spacer().frame(height: 10)
                }
                LiveClock(timer: timer, at: m.at, size: clockSize)
                if !timer.countsUp {
                    ProgressBar(value: timer.progress(at: m.at), color: progressColor(timer, subject, t)).frame(height: 4).padding(.top, 5)
                }
                controls(timer).padding(.top, 10)
            }
        }
    }

    private func progressColor(_ timer: WidgetSnapshot.TimerInfo, _ subject: WidgetSnapshot.SubjectStyle, _ t: WidgetTheme) -> Color {
        if timer.status == .paused { return t.text3 }
        return timer.isWork ? t.subject(subject.color) : t.rest
    }

    /// Podtitulek od nejúplnějšího po nejkratší: stav · téma · režim → stav · téma → stav (nebo téma).
    private func subtitles(_ timer: WidgetSnapshot.TimerInfo) -> [String] {
        if m.phaseOver { return [timer.isWork ? "Blok doběhl" : "Pauza skončila"] }
        let state: String? = switch timer.status {
        case .paused: "Pozastaveno"
        case .ready: timer.isWork ? "Připraveno" : "Pauza čeká"
        default: nil
        }
        let topic = timer.isWork && !timer.topic.isEmpty ? timer.topic : nil
        let mode = timer.modeName.isEmpty ? nil : timer.modeName
        let variants = [[state, topic, mode], [state, topic], [state ?? topic ?? mode]].map { parts -> String in
            let text = parts.compactMap { $0 }.joined(separator: " · ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        var seen = Set<String>()
        return variants.filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private func controls(_ timer: WidgetSnapshot.TimerInfo) -> some View {
        HStack(spacing: 6) {
            switch timer.status {
            case .running where timer.isWork:
                PrimaryButton(command: .button(.pause), title: "Pauza", symbol: "pause.fill")
                IconButton(command: .button(.finish), title: "Hotovo – uložit blok", symbol: "checkmark")
            case .running:
                PrimaryButton(command: .button(.next), title: "Další blok", short: "Dál", symbol: "forward.fill")
                IconButton(command: .button(.stop), title: "Ukončit sérii", symbol: "stop.fill")
            case .paused:
                PrimaryButton(command: .button(.resume), title: "Pokračovat", short: "Dál", symbol: "play.fill")
                IconButton(command: .button(.stop), title: "Konec – uložit a ukončit", symbol: "stop.fill")
            case .ready, .idle:
                if timer.isWork {
                    PrimaryButton(command: .button(.next), title: "Začít blok", short: "Začít", symbol: "play.fill")
                } else {
                    PrimaryButton(command: .button(.next), title: "Začít pauzu", short: "Pauza", symbol: "cup.and.saucer.fill", tint: .rest)
                }
                IconButton(command: .button(.stop), title: "Ukončit sérii", symbol: "stop.fill")
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
    /// Druhé doporučení pod prvním (velké widgety).
    var showsAlternative = false
    /// Tlačítko hned pod textem (jinak u spodního okraje).
    var buttonFollowsContent = false

    var body: some View {
        Themed { t in
            if let top = s.nextUp.first {
                let subject = s.subject(top.subjectId)
                VStack(alignment: .leading, spacing: 0) {
                    Caption("Co teď?")
                    HStack(spacing: 6) {
                        SubjectMark(color: subject.color)
                        Text(subject.name).font(.system(size: 11.5)).foregroundStyle(t.text2).lineLimit(1)
                    }
                    .padding(.top, 7)
                    Text(top.title).font(.system(size: titleSize, weight: .semibold)).foregroundStyle(t.text)
                        .lineLimit(titleLines).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                    if showsReason && !top.reason.isEmpty {
                        Text(top.reason).font(.system(size: 11)).foregroundStyle(t.text3).lineLimit(1).padding(.top, 3)
                    }
                    if showsAlternative, s.nextUp.count > 1 {
                        let alt = s.nextUp[1]
                        HStack(spacing: 5) {
                            Text("Nebo").foregroundStyle(t.text3)
                            SubjectMark(color: s.subject(alt.subjectId).color, size: 6)
                            Text(s.subject(alt.subjectId).name).foregroundStyle(t.text2)
                            Text("· \(alt.minutes) min").foregroundStyle(t.text3)
                        }
                        .font(.system(size: 11)).lineLimit(1).padding(.top, 8)
                    }
                    if buttonFollowsContent {
                        Spacer().frame(height: 14)
                    } else {
                        Spacer(minLength: 8)
                    }
                    PrimaryButton(command: .button(.start, subjectId: top.subjectId, topic: top.topic, modeId: top.modeId),
                                  title: "Začít · \(top.minutes) min", short: "Začít", symbol: "play.fill")
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

/// Řádek plánu: čas, barva předmětu, název a stav. Blok, který běží, má podklad; hotové jsou tlumené.
struct PlanLine: View {
    let block: WidgetSnapshot.Block
    let s: WidgetSnapshot
    let m: WidgetMoment
    /// Úzký sloupec: bez délky a stavu vpravo.
    var compact = false

    var body: some View {
        Themed { t in
            let subject = s.subject(block.subjectId)
            let isNow = m.current?.id == block.id
            HStack(spacing: 9) {
                ItemCheck(state: block.done ? .done : isNow ? .running(Double(m.at - block.start) / Double(max(1, block.end - block.start))) : .open)
                    .accessibilityLabel(block.done ? "hotovo" : isNow ? "teď" : "čeká")
                VStack(alignment: .leading, spacing: 0) {
                    Text(block.title.isEmpty ? subject.name : block.title).font(.system(size: 12.5, weight: isNow ? .semibold : .regular))
                        .foregroundStyle(block.done ? t.text3 : t.text)
                    if !block.title.isEmpty {
                        HStack(spacing: 4) {
                            SubjectMark(color: subject.color, size: 5).opacity(block.done ? 0.6 : 1)
                            Text(subject.name)
                        }
                        .font(.system(size: 10.5)).foregroundStyle(t.text3)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if isNow && !compact {
                    Text("teď").font(.system(size: 10.5, weight: .bold)).foregroundStyle(t.accent).widgetAccentable()
                } else {
                    Text(compact ? WidgetFormat.time(block.start) : "\(WidgetFormat.time(block.start)) · \((block.end - block.start) / 60_000) min")
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(block.done ? t.text3 : t.text2)
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 6)
            .background(isNow ? t.panel : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, -6)
        }
    }
}

/// Den na časové ose: bloky plánu v barvách předmětů, hodiny pod nimi a značka „teď“.
struct DayStrip: View {
    let s: WidgetSnapshot
    let m: WidgetMoment

    var body: some View {
        Themed { t in
            let range = hours
            GeometryReader { geo in
                let w = geo.size.width
                let x: (Int) -> CGFloat = { ms in
                    w * CGFloat(min(1, max(0, (Double(ms - m.day) / 3_600_000 - range.lowerBound) / (range.upperBound - range.lowerBound))))
                }
                ZStack(alignment: .topLeading) {
                    Capsule().fill(t.track).frame(width: w, height: 6)
                    ForEach(m.plan) { b in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(t.subject(s.subject(b.subjectId).color))
                            .opacity(b.done ? 0.4 : 1)
                            .frame(width: max(3, x(b.end) - x(b.start) - 1.5), height: 6)
                            .offset(x: x(b.start))
                            .widgetAccentable()
                    }
                    if m.at >= m.day, m.at < m.day + 86_400_000 {
                        Capsule().fill(t.text).frame(width: 2, height: 12).offset(x: x(m.at) - 1, y: -3)
                    }
                    ForEach(ticks(range), id: \.self) { h in
                        Text("\(h)")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(t.text3)
                            .fixedSize()
                            .frame(width: 30, alignment: h == Int(range.lowerBound) ? .leading : h == Int(range.upperBound) ? .trailing : .center)
                            .offset(x: h == Int(range.lowerBound) ? 0 : h == Int(range.upperBound) ? w - 30 : x(m.day + h * 3_600_000) - 15, y: 11)
                    }
                }
            }
            .frame(height: 24)
            .accessibilityHidden(true)
        }
    }

    /// Od 8 do 20 h, rozšířeno na celé hodiny podle plánu.
    private var hours: ClosedRange<Double> {
        let starts = m.plan.map { Double($0.start - m.day) / 3_600_000 }
        let ends = m.plan.map { Double($0.end - m.day) / 3_600_000 }
        let lo = min(8, (starts.min() ?? 8).rounded(.down))
        let hi = max(20, (ends.max() ?? 20).rounded(.up))
        return lo...min(24, max(lo + 4, hi))
    }

    private func ticks(_ range: ClosedRange<Double>) -> [Int] {
        let lo = Int(range.lowerBound), hi = Int(range.upperBound)
        let step = hi - lo > 14 ? 4 : 2
        var out = Array(stride(from: lo, to: hi, by: step))
        if hi - (out.last ?? lo) < step / 2 + 1 { out.removeLast() }
        return out + [hi]
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

/// Seznam plánu se záhlavím (hotovo / celkem · délka) a případně časovou osou dne.
struct PlanList: View {
    let s: WidgetSnapshot
    let m: WidgetMoment
    let limit: Int
    var caption = "Plán · dnes"
    var strip = false

    var body: some View {
        Themed { t in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Caption(caption)
                    Spacer()
                    if !m.plan.isEmpty {
                        let done = m.plan.filter(\.done).count
                        let total = m.plan.reduce(0) { $0 + ($1.end - $1.start) / 1000 }
                        Text("\(done)/\(m.plan.count) · \(WidgetFormat.duration(total))").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(t.text3)
                    }
                }
                if m.plan.isEmpty {
                    Text("Na dnešek nic v plánu.").font(.system(size: 12)).foregroundStyle(t.text2).padding(.top, 8)
                    Text("Ranní plán v aplikaci navrhne bloky do denního cíle.").font(.system(size: 11)).foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                } else {
                    if strip { DayStrip(s: s, m: m).padding(.top, 10).padding(.bottom, 4) }
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(PlanWindow.rows(m.plan, m: m, limit: limit)) { PlanLine(block: $0, s: s, m: m) }
                    }
                    .padding(.top, 5)
                    let shown = Set(PlanWindow.rows(m.plan, m: m, limit: limit).map(\.id))
                    let hidden = m.plan.filter { !shown.contains($0.id) }
                    if !hidden.isEmpty {
                        Text("+ \(hidden.count) \(hidden.allSatisfy(\.done) ? WidgetFormat.plural(hidden.count, "hotový", "hotové", "hotových") : "další")")
                            .font(.system(size: 10.5)).foregroundStyle(t.text3).padding(.top, 3)
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
                    Text(daysLeft == 0 ? "dnes" : "\(daysLeft)")
                        .font(daysLeft == 0 ? .system(size: 12, weight: .bold) : .system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(daysLeft <= 3 ? t.danger : daysLeft <= 10 ? t.warn : t.text)
                    if daysLeft > 0 {
                        Text(WidgetFormat.plural(daysLeft, "den", "dny", "dní")).font(.system(size: 9.5)).foregroundStyle(t.text3)
                    }
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
            .accessibilityElement(children: .combine)
        }
    }
}

/// Týden po dnech: sloupky odučeného času, dnešek zvýrazněný, čárkovaně denní cíl.
struct WeekBars: View {
    let m: WidgetMoment
    var height: CGFloat = 36

    var body: some View {
        Themed { t in
            let goal = m.goalSec
            let top = CGFloat(max(1, m.week.max() ?? 1, goal > 0 ? goal * 11 / 10 : 0))
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<7, id: \.self) { i in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(i == m.todayIndex ? t.accent : goal > 0 && m.week[i] >= goal ? t.rest.opacity(0.7) : t.track)
                            .frame(width: 8, height: max(3, height * CGFloat(m.week[i]) / top))
                            .widgetAccentable(i == m.todayIndex)
                        Text(WidgetFormat.weekdaysShort[i]).font(.system(size: 9, weight: i == m.todayIndex ? .bold : .regular))
                            .foregroundStyle(i == m.todayIndex ? t.text : t.text3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height + 15, alignment: .bottom)
            .overlay(alignment: .top) {
                if goal > 0 {
                    Line().stroke(t.text3.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .frame(height: 1)
                        .offset(y: height * (1 - CGFloat(goal) / top))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Týden: " + (0..<7).map { "\(WidgetFormat.weekdaysShort[$0]) \(WidgetFormat.duration(m.week[$0]))" }.joined(separator: ", "))
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// Předměty tento týden: odučeno proti týdennímu cíli.
struct SubjectWeekList: View {
    let s: WidgetSnapshot
    let m: WidgetMoment
    var limit = 3

    var body: some View {
        Themed { t in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(m.subjectWeek.prefix(limit), id: \.subjectId) { w in
                    let subject = s.subject(w.subjectId)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            SubjectMark(color: subject.color, size: 7)
                            Text(subject.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(t.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(WidgetFormat.duration(w.sec) + (w.goalSec > 0 ? " / \(WidgetFormat.duration(w.goalSec))" : ""))
                                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(t.text3).lineLimit(1).layoutPriority(1)
                        }
                        if w.goalSec > 0 {
                            ProgressBar(value: Double(w.sec) / Double(w.goalSec), color: t.subject(subject.color)).frame(height: 3)
                        }
                    }
                }
            }
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
                Text("Otevři Study Tracker").font(.system(size: 15, weight: .semibold)).foregroundStyle(t.text)
                Text("Widget se naplní daty po prvním spuštění aplikace.").font(.system(size: 11)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
