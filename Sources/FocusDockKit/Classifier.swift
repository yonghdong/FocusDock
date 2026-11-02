import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct Classification: Equatable {
    /// nil means "fits no mode"
    var modeID: String?
    var reason: String
    var confidence: Double?
}

/// Whether a held notification is worth interrupting for.
struct Triage: Equatable {
    var urgent: Bool
    /// Why, e.g. "needs your answer before 3pm". May be empty.
    var reason: String
    /// Which provider (or "rule") decided, for the log.
    var source = ""
}

/// Decides which mode an unknown app or site belongs to.
///
/// Providers (config.classifier.provider):
///  - "local":  EmbeddingGemma on this Mac (`ModeMatcher`), Apple's model until it's downloaded. Default.
///  - "jev":    TypeSafe Jev (System One model). Typed choice + calibrated confidence, ~70-500ms.
///  - "apple":  Apple's on-device Foundation Model (macOS 26+). Free and local.
///  - "claude": Claude API.
///  - "auto":   local, then jev if a TypeSafe key is set, then apple, then claude.
///  - "off"
final class Classifier {
    private var cache: [String: Classification] = [:]
    private let lock = NSLock()
    private let matcher: ModeMatcher?

    static let noneOption = "none"

    init(matcher: ModeMatcher? = nil) {
        self.matcher = matcher
    }

    /// Providers to try in order; the first that answers decides (an unsure answer counts).
    static func order(_ provider: String) -> [String] {
        switch provider {
        case "off": return []
        case "local": return ["local", "apple"]
        case "jev", "apple", "claude": return [provider]
        default: return ["local", "jev", "apple", "claude"]
        }
    }

    /// `appNames`: display names of the modes' installed apps, for the local matcher's examples.
    func classify(_ subject: Subject, modes: [Mode], config: ClassifierConfig,
                  appNames: [String: String] = [:]) async -> Classification? {
        let key = cacheKey(subject)
        if let hit = cached(key) { return hit }

        var result: Classification?
        for provider in Self.order(config.provider) where result == nil {
            switch provider {
            case "local": result = await matcher?.classify(subject, modes: modes, appNames: appNames)
            case "jev": result = await askJev(subject, modes: modes, config: config)
            case "apple": result = await askApple(subject, modes: modes)
            case "claude": result = await askClaude(subject, modes: modes, config: config)
            default: break
            }
        }
        guard var result else { return nil }
        if let c = result.confidence, c < config.minConfidence { result.modeID = nil }
        remember(result, for: key)
        return result
    }

    /// Display names of the modes' installed apps. Call on the main thread.
    static func appNames(for modes: [Mode]) -> [String: String] {
        var out: [String: String] = [:]
        for bid in Set(modes.flatMap(\.apps)) {
            let name = AppLauncher.name(for: bid)
            if name != bid { out[bid] = name }
        }
        return out
    }

    /// Drops cached verdicts about an app, or about every host under a domain.
    func forget(_ kind: LearnedItem.Kind, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .app: cache["app:" + value] = nil
        case .site:
            for key in cache.keys where key.hasPrefix("site:") && AppConfig.host(String(key.dropFirst(5)), matches: value) {
                cache[key] = nil
            }
        }
    }

    // NSLock can't be used directly from async code; keep locking in sync helpers.
    private func cached(_ key: String) -> Classification? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private func remember(_ result: Classification, for key: String) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = result
    }

    /// Whether the on-device model can run, in words for the setup window.
    static var appleModelStatus: (ok: Bool, text: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return (true, "Apple Intelligence is ready")
            case .unavailable(.appleIntelligenceNotEnabled): return (false, "Turn on Apple Intelligence in System Settings")
            case .unavailable(.deviceNotEligible): return (false, "This Mac can't run Apple Intelligence")
            case .unavailable(.modelNotReady): return (false, "Apple Intelligence is still downloading")
            default: return (false, "Apple Intelligence is unavailable")
            }
        }
        #endif
        return (false, "Needs macOS 26 for the on-device model")
    }

    // MARK: Notifications

    /// Decides whether a notification held for another mode should interrupt the current one.
    /// `examples` are this user's reactions to earlier cards, newest first (for the on-device model);
    /// `profile` and `pending` are the notes and the reactions not in them yet (for Claude).
    func triage(_ n: HeldNotification, appName: String, config: ClassifierConfig,
                examples: [NotificationExample] = [], profile: String = "",
                pending: [NotificationExample] = []) async -> Triage? {
        let order = Self.triageOrder(config, claudeCodeInstalled: ClaudeCode.executable != nil)
        guard !order.isEmpty else { return nil }
        if var rule = Self.mealInvite(n) { rule.source = "rule"; return rule }
        let prompt = Self.triagePrompt(n, appName: appName)
        for provider in order {
            var result: Triage?
            switch provider {
            case "claudeCode":
                result = await ClaudeCode.ask(system: Self.triageSystem(profile: profile, pending: pending), prompt: prompt)
                    .flatMap { Self.parseTriage($0) }
            case "jev": result = await jevTriage(prompt, config: config)
            case "apple":
                result = await appleText(Self.triageInstructions(with: examples), prompt)
                    .flatMap { Self.parseTriage($0, examples: examples) }
            case "claude":
                result = await claudeText(Self.triageInstructions(with: examples), prompt, config: config)
                    .flatMap { Self.parseTriage($0, examples: examples) }
            default: break
            }
            if var result { result.source = provider; return result }
        }
        return nil
    }

    /// Invitations to eat together today count as time-sensitive. A keyword rule, because the
    /// on-device model reads Korean time words ("내일", "다음주") too unreliably for this.
    static func mealInvite(_ n: HeldNotification) -> Triage? {
        let text = [n.title, n.subtitle, n.body].joined(separator: " ").lowercased()
        let meals = [("점심", "lunch"), ("저녁", "dinner"), ("밥", "meal"), ("lunch", "lunch"), ("dinner", "dinner")]
        let invites = ["먹으러", "먹자", "먹을래", "먹을 사람", "갈래", "갈 사람", "가자", "고고", "ㄱㄱ",
                       "lunch?", "dinner?", "lunch in", "grab lunch", "grab dinner", "join us for"]
        let notToday = ["내일", "모레", "다음주", "담주", "주말", "다음에", "언젠가", "한번", "먹었",
                        "tomorrow", "next week", "weekend", "sometime"]
        guard invites.contains(where: text.contains), !notToday.contains(where: text.contains),
              let meal = meals.first(where: { text.contains($0.0) }) else { return nil }
        return Triage(urgent: true, reason: "\(meal.1) invite")
    }

    /// Providers to try for notifications the rules and the reaction memory leave undecided. Local (the
    /// default) uses none: the user is asked, and the answer feeds the memory. Auto
    /// prefers Claude Code (Haiku follows the user's notes; the on-device model only follows examples).
    static func triageOrder(_ config: ClassifierConfig, claudeCodeInstalled: Bool) -> [String] {
        switch config.triageProvider {
        case "off": return []
        case "local": return []   // undecided ones are asked about instead
        case "claudeCode": return ["claudeCode", "apple"]
        case "jev", "apple", "claude": return [config.triageProvider]
        default: return (claudeCodeInstalled ? ["claudeCode"] : []) + ["apple"]
        }
    }

    /// For Claude: the base instructions, the user's notes, and reactions not yet folded into them.
    static func triageSystem(profile: String, pending: [NotificationExample]) -> String {
        var s = triageInstructions
        let notes = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            s += "\n\nWhat this user has taught you about their notifications (follow it over the general rules above):\n" + notes
        }
        if !pending.isEmpty {
            s += "\n\nTheir latest reactions, not in those notes yet:\n" + reactionLines(pending)
        }
        return s
    }

    static func reactionLines(_ examples: [NotificationExample]) -> String {
        examples.map { "- \($0.sender) (\($0.app)): \"\($0.text)\" -> \($0.important ? "important" : "not important")" }
            .joined(separator: "\n")
    }

    // MARK: Notes on what matters (kept by Claude)

    static let profileInstructions = """
    You keep short notes on which notifications matter to one user, like a CLAUDE.md file. \
    Merge the new reactions into the current notes. Write general rules that name senders, chats or kinds \
    of messages instead of listing every reaction, and drop or change rules that newer reactions contradict. \
    At most 12 lines, each starting with "- ". Reply with only the notes.
    """

    static func profilePrompt(current: String, reactions: [NotificationExample]) -> String {
        let notes = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Current notes:\n\(notes.isEmpty ? "(none yet)" : notes)\n\nNew reactions (oldest first):\n" + reactionLines(reactions)
    }

    /// Keeps only "- " lines, at most 12; nil if nothing usable came back.
    static func cleanProfile(_ raw: String) -> String? {
        let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }
        return lines.isEmpty ? nil : lines.prefix(12).joined(separator: "\n")
    }

    /// Folds `reactions` into the notes with Claude Code. Nil if it isn't installed or the reply is unusable.
    func updatedProfile(current: String, reactions: [NotificationExample]) async -> String? {
        guard !reactions.isEmpty else { return nil }
        return await ClaudeCode.ask(system: Self.profileInstructions, prompt: Self.profilePrompt(current: current, reactions: reactions))
            .flatMap(Self.cleanProfile)
    }

    // Reason first so the verdict follows from it. Several examples: with only one, the on-device
    // model copies its reason verbatim (and it still echoes one when it can't read a message).
    // Lenient on purpose; the user's reactions (see `triageInstructions(with:)`) narrow it down.
    static let triageInstructions = """
    You decide whether a notification should interrupt someone who is focusing on other work. \
    Reply with ONLY a JSON object: {"reason": "<at most 6 words>", "urgent": true or false}. \
    First write the reason: what the message needs from the reader and by when, using only its own content, \
    or what kind of message it is if it needs nothing. Then decide. \
    urgent is true when the message asks the reader a direct question or asks them to do something, \
    reports that something is broken, or says someone is waiting on them. \
    When unsure, lean towards true; the user will tell you what they don't need. \
    urgent is false for chatter, jokes, reactions, FYIs, newsletters, promotions, and messages you cannot clearly understand. \
    If you cannot tell what the message means, use the reason "unclear" and urgent false. \
    Examples: "Jordan: can you review my PR before the 5pm deploy?" -> {"reason": "review needed before 5pm deploy", "urgent": true}. \
    "민수: 30분 뒤 미팅인데 슬라이드 보내줄 수 있어요?" -> {"reason": "slides needed in 30 min", "urgent": true}. \
    "Mom: how was your day?" -> {"reason": "casual question", "urgent": false}. \
    "지훈: 근데 그 교수 학점 진짜 짜게 준다더라" -> {"reason": "chatter", "urgent": false}.
    """

    /// The base instructions plus the user's reactions written as examples in the same form. The
    /// on-device model follows these closely, while a plain list of past judgments made it worse.
    static func triageInstructions(with examples: [NotificationExample]) -> String {
        guard !examples.isEmpty else { return triageInstructions }
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
        let shots = examples.map {
            "\"\(q($0.sender)): \(q($0.text))\" -> {\"reason\": \"\(q($0.reason))\", \"urgent\": \($0.important)}."
        }
        return triageInstructions
            + " This user's own past judgments come first; give similar notifications the same answer: "
            + shots.joined(separator: " ")
    }

    static func triagePrompt(_ n: HeldNotification, appName: String) -> String {
        var lines = ["Notification from \(appName)"]
        if !n.title.isEmpty { lines.append("Title: \(n.title)") }
        if !n.subtitle.isEmpty { lines.append("Subtitle: \(n.subtitle)") }
        if !n.body.isEmpty { lines.append("Body: \(n.body)") }
        return lines.joined(separator: "\n")
    }

    static func parseTriage(_ raw: String, examples: [NotificationExample] = []) -> Triage? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urgent = obj["urgent"] as? Bool else { return nil }
        let reason = (obj["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A reason copied from one of the user's examples means "like that one": same answer.
        // "unclear", or a built-in example's reason echoed back, means it couldn't read the message.
        if !reason.isEmpty, let example = examples.first(where: { $0.reason == reason }) {
            return Triage(urgent: example.important, reason: reason)
        }
        if reason.lowercased() == "unclear" || triageInstructions.contains("\"reason\": \"\(reason)\"") {
            return Triage(urgent: false, reason: "")
        }
        return Triage(urgent: urgent, reason: reason)
    }

    // MARK: Shared prompt pieces

    static func describe(_ subject: Subject) -> String {
        switch subject {
        case .app(let bid, let name):
            return "Mac app \"\(name)\" (bundle id \(bid))"
        case .site(let host, let title, _):
            return "Website \(host)" + (title.isEmpty ? "" : ", page title \"\(title)\"")
        case .notification(let n):
            return "Notification from \(n.bundleID): \(n.title) \(n.body)"
        }
    }

    /// Short human label for the card when the provider gives no free-text reason.
    static func fallbackReason(_ subject: Subject) -> String {
        switch subject {
        case .app(_, let name): return name
        case .site(_, let title, _):
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 48 ? String(t.prefix(47)) + "…" : t
        case .notification(let n): return n.title
        }
    }

    private func cacheKey(_ s: Subject) -> String {
        switch s {
        case .app(let bid, _): return "app:" + bid
        case .site(let host, _, _): return "site:" + host
        case .notification(let n): return "note:\(n.id)"
        }
    }

    // MARK: Jev (TypeSafe System One)

    private func askJev(_ subject: Subject, modes: [Mode], config: ClassifierConfig) async -> Classification? {
        var criteria: [String: Any] = [:]
        for m in modes { criteria[m.id] = m.purpose }
        criteria[Self.noneOption] = "Fits none of these modes"
        let questions: [String: Any] = [
            "mode": [
                "type": "choice",
                "instructions": "Which focus mode does this app or website belong to?",
                "criteria": criteria,
            ]
        ]
        guard let answers = await jevAnswers(state: Self.describe(subject), questions: questions, config: config),
              let mode = answers["mode"] as? [String: Any],
              let choice = mode["choice"] as? String else { return nil }
        let confidence = (mode["confidence"] as? NSNumber)?.doubleValue
        let valid = Set(modes.map(\.id))
        return Classification(modeID: valid.contains(choice) ? choice : nil,
                              reason: Self.fallbackReason(subject),
                              confidence: confidence)
    }

    private func jevTriage(_ prompt: String, config: ClassifierConfig) async -> Triage? {
        let questions: [String: Any] = [
            "urgent": [
                "type": "noul",
                "instructions": "Does this notification need the user's reply or action soon?",
            ]
        ]
        guard let answers = await jevAnswers(state: prompt, questions: questions, config: config),
              let urgent = answers["urgent"] as? [String: Any],
              let p = (urgent["noul"] as? NSNumber)?.doubleValue else { return nil }
        return Triage(urgent: p >= 0.5, reason: "")
    }

    /// POSTs to System One and returns `answers`, or nil without a key or on any error.
    private func jevAnswers(state: String, questions: [String: Any], config: ClassifierConfig) async -> [String: Any]? {
        let key = config.typesafeAPIKey.isEmpty
            ? (ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? "")
            : config.typesafeAPIKey
        guard !key.isEmpty, let url = URL(string: "https://api.typesafe.ai/v1/systemone") else { return nil }

        let body: [String: Any] = ["model": config.typesafeModel, "state": state, "questions": questions]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = obj["answers"] as? [String: Any] else {
                NSLog("FocusDock: Jev error \(String(data: data, encoding: .utf8) ?? "")")
                return nil
            }
            return answers
        } catch {
            NSLog("FocusDock: Jev request failed \(error)")
            return nil
        }
    }

    // MARK: LLM providers (free-text JSON)

    /// No example reason: the on-device model copies one verbatim for anything similar
    /// (every docs site became "API docs for an incident tool").
    static let instructions = """
    You sort apps and websites into a user's focus modes. \
    Reply with ONLY a JSON object: {"mode": "<mode id or null>", "reason": "<at most 7 words>"}. \
    Use null when it clearly fits none of the modes. The reason names what this specific item is \
    (its product or topic), in at most 7 words.
    """

    static func llmPrompt(_ subject: Subject, modes: [Mode]) -> String {
        let list = modes.map { "- \($0.id): \($0.purpose)" }.joined(separator: "\n")
        return "Modes:\n\(list)\n\nItem: \(describe(subject))"
    }

    static func parseLLM(_ raw: String, validIDs: Set<String>) -> Classification? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        guard let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let reason = (obj["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var id = obj["mode"] as? String
        if let i = id, !validIDs.contains(i) { id = nil }
        return Classification(modeID: id, reason: reason, confidence: nil)
    }

    private func askApple(_ subject: Subject, modes: [Mode]) async -> Classification? {
        guard let text = await appleText(Self.instructions, Self.llmPrompt(subject, modes: modes)) else { return nil }
        return Self.parseLLM(text, validIDs: Set(modes.map(\.id)))
    }

    private func askClaude(_ subject: Subject, modes: [Mode], config: ClassifierConfig) async -> Classification? {
        guard let text = await claudeText(Self.instructions, Self.llmPrompt(subject, modes: modes), config: config)
        else { return nil }
        return Self.parseLLM(text, validIDs: Set(modes.map(\.id)))
    }

    /// Apple's on-device model (macOS 26+). Nil when unavailable or on error.
    private func appleText(_ instructions: String, _ prompt: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            do {
                let session = LanguageModelSession(instructions: instructions)
                // Greedy: the same item should always get the same verdict.
                return try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy)).content
            } catch {
                NSLog("FocusDock: Apple model error \(error)")
            }
        }
        #endif
        return nil
    }

    private func claudeText(_ system: String, _ prompt: String, config: ClassifierConfig) async -> String? {
        let key = config.anthropicAPIKey.isEmpty
            ? (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
            : config.anthropicAPIKey
        guard !key.isEmpty, let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": config.anthropicModel,
            "max_tokens": 256,
            // A one-line verdict needs no thinking; with it on (Haiku 5.5's default) it can eat the budget.
            "thinking": ["type": "disabled"],
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["stop_reason"] as? String != "refusal",   // no server-side fallback on Haiku 5.5
                  let content = obj["content"] as? [[String: Any]] else {
                NSLog("FocusDock: Claude API error \(String(data: data, encoding: .utf8) ?? "")")
                return nil
            }
            return content.compactMap { $0["text"] as? String }.joined()
        } catch {
            NSLog("FocusDock: Claude API request failed \(error)")
            return nil
        }
    }
}
