import Foundation

/// User preferences, persisted in UserDefaults, plus the personal dictionary file.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var aiCleanup: Bool {
        get { defaults.object(forKey: "aiCleanup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "aiCleanup") }
    }

    static var sounds: Bool {
        get { defaults.object(forKey: "sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sounds") }
    }

    /// Adds a space after pasted text so back-to-back dictations don't run together.
    static var trailingSpace: Bool {
        get { defaults.object(forKey: "trailingSpace") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "trailingSpace") }
    }

    static var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    static var history: [String] {
        get { defaults.stringArray(forKey: "history") ?? [] }
        set { defaults.set(Array(newValue.prefix(15)), forKey: "history") }
    }

    static func addToHistory(_ text: String) {
        history = [text] + history.filter { $0 != text }
    }

    // MARK: Personal dictionary

    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var dictionaryURL: URL { supportDirectory.appendingPathComponent("dictionary.txt") }

    static func ensureDictionaryFile() {
        guard !FileManager.default.fileExists(atPath: dictionaryURL.path) else { return }
        let template = """
        # Murmur personal dictionary
        # One word or phrase per line. Names, jargon, product names: anything
        # you want spelled exactly this way. Lines starting with # are ignored.
        # Changes apply to your next dictation.

        """
        try? template.write(to: dictionaryURL, atomically: true, encoding: .utf8)
    }

    static func dictionaryWords() -> [String] {
        guard let contents = try? String(contentsOf: dictionaryURL, encoding: .utf8) else { return [] }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
