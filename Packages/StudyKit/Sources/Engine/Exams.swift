import Core

// Zkoušky (`ExamModal` a sekce Zkoušky v `PlannerPage` na webu). Bloky opakování ke zkoušce Mac
// negeneruje (opakování na Macu není); bloky, které vygeneroval web, jsou běžné bloky plánu s `examId`.

public enum ExamCountdown {
    /// Za kolik dní zkouška je (0 = dnes); `nil` = neplatné datum.
    public static func daysLeft(_ exam: Exam, now: Int, clock: StudyClock) -> Int? {
        guard let day = clock.parseDayKey(exam.date) else { return nil }
        return Int(JS.round(Double(day - clock.startOfDay(now)) / Double(StudyClock.day)))
    }

    /// „dnes“, „za 3 dny“, „za 12 dní“
    public static func label(daysLeft: Int) -> String {
        daysLeft == 0 ? "dnes" : "za \(daysLeft) \(Format.plural(daysLeft, "den", "dny", "dní"))"
    }

    /// Nadcházející zkoušky (od dneška) podle data.
    public static func upcoming(_ doc: AppDocument, now: Int, clock: StudyClock) -> [Exam] {
        let today = clock.startOfDay(now)
        return doc.alive(Exam.self)
            .filter { clock.parseDayKey($0.date).map { $0 >= today } ?? false }
            .sorted { $0.date < $1.date }
    }
}

extension AppDocument {
    /// Budoucí nedokončené bloky ke zkoušce – smažou se spolu s ní.
    public func upcomingBlocks(ofExam id: String, now: Int) -> [PlanBlock] {
        records(PlanBlock.self).filter { Self.isUpcoming($0, ofExam: id, now: now) }
    }

    /// Smaže zkoušku i její budoucí nedokončené bloky se stejným časem smazání, takže je „Vrátit“
    /// i Koš obnoví spolu (`restore`).
    public mutating func removeExam(_ id: String, now: Int) {
        remove(.exams, id: id, now: now)
        modifyRecords(.planBlocks) { o in
            guard Self.isUpcoming(PlanBlock(raw: o), ofExam: id, now: now) else { return }
            o["deletedAt"] = .number(Double(now))
            o["updatedAt"] = .number(Double(now))
        }
    }

    private static func isUpcoming(_ b: PlanBlock, ofExam id: String, now: Int) -> Bool {
        b.examId == id && !b.done && !b.isDeleted && b.start >= now
    }
}
