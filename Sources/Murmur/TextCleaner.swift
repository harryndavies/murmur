import Foundation

/// Fast, deterministic cleanup that always runs: drops filler sounds, collapses
/// stutters ("I I think"), tidies spacing and capitalisation. The AI pass (if on)
/// then handles the things rules can't: self-corrections, "like", "you know", lists.
enum TextCleaner {
    /// Pure hesitation sounds. Words like "like" or "so" are left for the AI, since
    /// they're often meaningful.
    private static let fillerPattern = #"(?i)(?:,\s*)?\b(?:u+h*m+|u+h+|e+r+m+|e+r+|a+h+|h+m+|m+h*m+|mhm)\b(?:\s*,)?"#

    /// Repeats that are often intentional ("had had", "very very", "no no").
    private static let keepRepeats: Set<String> = [
        "had", "that", "is", "very", "really", "so", "no", "yes", "yeah", "bye", "ha", "haha",
        "ok", "okay", "now", "never", "more", "much", "many", "far", "well", "wait", "please",
        "hey", "go", "knock", "do", "there", "tut", "chop", "night", "boo", "choo", "hush",
    ]

    static func clean(_ text: String) -> String {
        var s = text

        s = replace(s, fillerPattern, with: " ")
        s = applyLineBreakCommands(s)
        s = collapseRepeatedPhrases(s, length: 3)
        s = collapseRepeatedPhrases(s, length: 2)
        s = collapseRepeatedWords(s)
        s = tidyPunctuation(s)
        s = capitaliseSentences(s)
        return s
    }

    // MARK: Steps

    /// "…on Friday. New paragraph. Also…" → a blank line. Only when the command is its own
    /// sentence or clause, so "add a new line to the file" is left alone.
    private static func applyLineBreakCommands(_ s: String) -> String {
        let boundary = #"(^|[.!?,;:]|\n)[ \t]*"#
        let end = #"[ \t]*(?:[.!?,;:]+|$)[ \t]*"#
        var s = replace(s, #"(?i)"# + boundary + "new paragraph" + end, with: "$1\n\n")
        s = replace(s, #"(?i)"# + boundary + "new line" + end, with: "$1\n")
        return s
    }

    private static func collapseRepeatedWords(_ s: String) -> String {
        // "the the", "I, I", "we we we"
        let regex = try! NSRegularExpression(pattern: #"(?i)\b([\p{L}'’]+)(?:[,\s]+\1\b)+"#)
        return regex.replace(in: s) { match, ns in
            let word = ns.substring(with: match.range(at: 1))
            return keepRepeats.contains(word.lowercased()) ? ns.substring(with: match.range) : word
        }
    }

    private static func collapseRepeatedPhrases(_ s: String, length: Int) -> String {
        // "I think I think", "we should we should"
        let word = #"[\p{L}'’]+"#
        let phrase = Array(repeating: word, count: length).joined(separator: #"\s+"#)
        let regex = try! NSRegularExpression(pattern: #"(?i)\b("# + phrase + #")(?:[,\s]+\1\b)+"#)
        return regex.replace(in: s) { match, ns in ns.substring(with: match.range(at: 1)) }
    }

    private static func tidyPunctuation(_ s: String) -> String {
        var s = s
        s = replace(s, #"[ \t]{2,}"#, with: " ")
        s = replace(s, #"[ \t]+([,.!?;:…])"#, with: "$1")       // "word ." -> "word."
        s = replace(s, #",\s*([.!?])"#, with: "$1")             // ", ." -> "."
        s = replace(s, #"([,;:])(?:\s*[,;:])+"#, with: "$1")      // ",," -> ","
        s = replace(s, #"([.!?])\s*,"#, with: "$1")             // ". ," -> "."
        s = replace(s, #"^[\s,.;:…]+"#, with: "")               // leading junk
        s = replace(s, #"(?m)^[ \t]+|[ \t]+$"#, with: "")
        s = replace(s, #"(?<![\p{L}])i(?!\.e\.)(?=[\s,.!?'’]|$)"#, with: "I")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitaliseSentences(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(^|(?<!\b(?:[iI]\.e|[eE]\.g|etc|vs|Mr|Mrs|Ms|Dr))[.!?]\s+|\n\s*)(\p{Ll})"#)
        return regex.replace(in: s) { match, ns in
            ns.substring(with: match.range(at: 1)) + ns.substring(with: match.range(at: 2)).uppercased()
        }
    }

    // MARK: Helpers

    private static func replace(_ s: String, _ pattern: String, with template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

extension NSRegularExpression {
    func replace(in s: String, using transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(match, ns)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
