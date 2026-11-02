import Foundation

/// A notification the user reacted to, with its embedding.
struct Reaction: Codable, Equatable {
    var app: String
    var sender: String
    var text: String
    var important: Bool
    var date: Date
    /// Float32 values, stored as bytes (about 3 KB instead of a long JSON array).
    var vectorData: Data

    var vector: [Float] {
        vectorData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    init(app: String, sender: String, text: String, important: Bool, date: Date = Date(), vector: [Float]) {
        self.app = app
        self.sender = sender
        self.text = text
        self.important = important
        self.date = date
        vectorData = vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Reactions kept on this Mac (reactions.json next to config.json, not in it: the vectors are bulky).
/// A new notification that is clearly closer to past "important" reactions than to "not important" ones
/// (or the other way round) is decided right here, with no model call.
final class ReactionMemory {
    static let capacity = 200
    /// Best-important minus best-not-important cosine needed to decide. From the bilingual eval:
    /// every decision at or above this was right; below it the notification goes to the classifier.
    static let minMargin: Float = 0.08

    /// Built-in examples so the memory can decide from day one, before the user has reacted to anything.
    /// Stricter than the user's own reactions: generic examples catch the clear cases (promos, chatter,
    /// outages, deadlines) but blur "a question" with "an urgent question". In the eval, 0.12 decided
    /// about half of the notifications, 19 of 20 correctly; the rest go to the classifier.
    static let seedMargin: Float = 0.12
    /// Senders are roles, never people's names: a shared name with a real sender would skew the match.
    static let seeds: [(sender: String, body: String, important: Bool)] = [
        ("교수님", "내일 미팅 전에 슬라이드 보내주세요", true),
        ("팀장", "오늘 6시까지 보고서 부탁해요", true),
        ("동료", "회의 5분 뒤에 시작해요 들어오세요", true),
        ("엄마", "어디야? 연락 좀 해", true),
        ("친구", "도착했어 어디 있어?", true),
        ("선배", "점심 같이 먹을래? 지금 내려가", true),
        ("Advisor", "please send me the draft by tonight", true),
        ("Manager", "can you review this before the 4pm meeting?", true),
        ("PagerDuty", "[P1] database CPU at 95%, you are on call", true),
        ("Alerts", "production deploy failed, rollback needed", true),
        ("Colleague", "I'm outside, can you come down?", true),
        ("Lab", "the experiment finished with an error, can you check?", true),
        ("단톡방", "ㅋㅋㅋㅋ 개웃기네 진짜", false),
        ("단톡방", "오늘 날씨 너무 좋다", false),
        ("쇼핑몰", "오늘만! 특가 할인 쿠폰 도착", false),
        ("공지", "자료 업로드했습니다 참고하세요", false),
        ("앱", "이번 주 활동 요약이 도착했어요", false),
        ("친구", "주말에 시간 되면 밥이나 한번 먹자", false),
        ("Newsletter", "This week's top stories in tech", false),
        ("Store", "30% off your next order this weekend", false),
        ("Friend", "haha that's hilarious", false),
        ("Group", "anyone watching the game tonight?", false),
        ("Twitter", "You have 3 new followers", false),
        ("YouTube", "New video from a channel you follow", false)
    ]

    private(set) var items: [Reaction] = []
    private let url: URL

    init(url: URL = ConfigStore.directory.appendingPathComponent("reactions.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Reaction].self, from: data) {
            items = saved
        }
    }

    /// The text that gets embedded, for reactions and new notifications alike.
    static func text(sender: String, body: String) -> String { "\(sender): \(body)" }

    func add(_ r: Reaction) {
        items.removeAll { $0.sender == r.sender && $0.text == r.text }   // a changed mind replaces the old one
        items.append(r)
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }

    /// Decides from the user's own reactions. With only one kind so far (say, a single answer), the
    /// built-in examples stand in for the other side, but only a user reaction can be the deciding match.
    static func decideFromReactions(_ v: [Float], reactions: [Reaction], seeds: [Reaction])
        -> (important: Bool, nearest: Reaction, margin: Float)? {
        guard !reactions.isEmpty else { return nil }
        let missing = seeds.filter { s in !reactions.contains { $0.important == s.important } }
        guard let d = decide(v, among: reactions + missing), reactions.contains(d.nearest) else { return nil }
        return d
    }

    /// Nil when there aren't reactions of both kinds yet, or nothing is clearly closer to one side.
    static func decide(_ v: [Float], among items: [Reaction], minMargin: Float = minMargin)
        -> (important: Bool, nearest: Reaction, margin: Float)? {
        func cos(_ r: Reaction) -> Float { zip(v, r.vector).reduce(0) { $0 + $1.0 * $1.1 } }
        let scored = items.map { ($0, cos($0)) }
        guard let bestImp = scored.filter({ $0.0.important }).max(by: { $0.1 < $1.1 }),
              let bestNot = scored.filter({ !$0.0.important }).max(by: { $0.1 < $1.1 }) else { return nil }
        let margin = bestImp.1 - bestNot.1
        guard abs(margin) >= minMargin else { return nil }
        return margin > 0 ? (true, bestImp.0, margin) : (false, bestNot.0, -margin)
    }
}
