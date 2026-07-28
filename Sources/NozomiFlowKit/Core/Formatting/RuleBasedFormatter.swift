import Foundation

/// Deterministic, dependency-free cleanup pass over a raw transcript: strips a
/// trailing "press enter" voice command, applies layout commands ("new line",
/// "new paragraph"), removes filler words, normalizes whitespace/punctuation
/// spacing, capitalizes sentences, and applies tone-aware terminal punctuation.
/// Pure -- no I/O, no async -- so it's directly unit testable.
struct RuleBasedFormatter {

    /// - Parameter level: `.off` only extracts "press enter" and returns the rest
    ///   verbatim. `.light`/`.full` run the full rule pipeline below (the LLM pass
    ///   for `.full` happens elsewhere, over this rule-cleaned text).
    static func apply(
        to raw: String,
        level: FormattingLevel,
        tone: ToneCategory,
        localeIdentifier: String,
        removeFillers: Bool
    ) -> RuleFormattingResult {
        let (afterPressEnter, pressEnter) = extractPressEnter(raw)

        guard level != .off else {
            return RuleFormattingResult(text: afterPressEnter, pressEnter: pressEnter, corrections: 0)
        }

        var text = applyLayoutCommands(afterPressEnter)

        var corrections = 0
        if removeFillers {
            let (filtered, count) = removeFillerWords(text, localeIdentifier: localeIdentifier)
            text = filtered
            corrections = count
        }

        text = normalizeSpacingAndPunctuation(text)
        text = capitalizeSentences(text)
        text = applyTerminalPunctuation(text, tone: tone)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return RuleFormattingResult(text: text, pressEnter: pressEnter, corrections: corrections)
    }

    // MARK: - (a) trailing "press enter"

    private static let pressEnterRegex = try! NSRegularExpression(
        pattern: #"\bpress\s+enter\b[.!?,]?\s*$"#,
        options: [.caseInsensitive]
    )

    /// Exposed directly since this rule applies at every formatting level, including `.off`.
    static func extractPressEnter(_ raw: String) -> (text: String, pressEnter: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        guard let match = pressEnterRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else {
            return (trimmed, false)
        }
        let before = ns.substring(to: match.range.location)
        return (before.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    // MARK: - (b) layout commands

    private static let newParagraphRegex = try! NSRegularExpression(
        pattern: #"[ \t]*[,;]?[ \t]*\bnew\s+paragraph\b[ \t]*[,;]?[ \t]*"#,
        options: [.caseInsensitive]
    )
    private static let newLineRegex = try! NSRegularExpression(
        pattern: #"[ \t]*[,;]?[ \t]*\bnew\s+line\b[ \t]*[,;]?[ \t]*"#,
        options: [.caseInsensitive]
    )

    private static func applyLayoutCommands(_ text: String) -> String {
        var result = replaceAll(newParagraphRegex, in: text, with: "\n\n")
        result = replaceAll(newLineRegex, in: result, with: "\n")
        return result
    }

    // MARK: - (c) filler removal

    private static let englishFillers = ["um", "uh", "uhm", "uhh", "er", "erm", "mhm", "hmm"]
    private static let turkishFillers = ["ııı", "eee", "ımm"]

    /// NEVER includes "like" / "you know" / "actually" -- those carry meaning too
    /// often to strip with a blind word-boundary rule.
    private static func removeFillerWords(_ text: String, localeIdentifier: String) -> (text: String, count: Int) {
        let fillers = localeIdentifier.lowercased().hasPrefix("tr") ? turkishFillers : englishFillers
        var result = text
        var count = 0
        for filler in fillers {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else { continue }
            let ns = result as NSString
            let matchCount = regex.numberOfMatches(in: result, range: NSRange(location: 0, length: ns.length))
            guard matchCount > 0 else { continue }
            count += matchCount
            result = replaceAll(regex, in: result, with: "")
        }
        return (result, count)
    }

    // MARK: - (d) whitespace / punctuation spacing normalization

    private static let repeatedCommaRegex = try! NSRegularExpression(pattern: #",(\s*,)+"#)
    private static let multiSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let punctuationMarks: [Character] = [",", ".", "!", "?", ";", ":"]

    private static func normalizeSpacingAndPunctuation(_ text: String) -> String {
        var result = replaceAll(repeatedCommaRegex, in: text, with: ",")
        result = removeSpaceBeforePunctuation(result)
        result = replaceAll(multiSpaceRegex, in: result, with: " ")
        result = trimStrayLineArtifacts(result)
        return result
    }

    private static func removeSpaceBeforePunctuation(_ text: String) -> String {
        var result = text
        for mark in punctuationMarks {
            let escaped = NSRegularExpression.escapedPattern(for: String(mark))
            guard let regex = try? NSRegularExpression(pattern: #"[ \t]+"# + escaped) else { continue }
            result = replaceAll(regex, in: result, with: String(mark))
        }
        return result
    }

    /// Trims stray leading punctuation/spaces left by removed fillers at the start
    /// of the text or of any line (e.g. "um, I think" -> ", I think" -> "I think").
    private static func trimStrayLineArtifacts(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map(trimLineArtifacts)
            .joined(separator: "\n")
    }

    private static func trimLineArtifacts(_ line: String) -> String {
        var chars = Array(line)
        while let first = chars.first, first == " " || first == "\t" {
            chars.removeFirst()
        }
        while let first = chars.first, first == "," || first == ";" {
            chars.removeFirst()
            while let next = chars.first, next == " " || next == "\t" {
                chars.removeFirst()
            }
        }
        while let last = chars.last, last == " " || last == "\t" {
            chars.removeLast()
        }
        return String(chars)
    }

    // MARK: - (e) sentence capitalization

    /// Capitalizes only the first letter of the text and the first letter after a
    /// `.!?` that's followed by whitespace or end-of-text. Every other character is
    /// left untouched, so ALL-CAPS words (acronyms) are never altered.
    private static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var chars = Array(text)
        var capitalizeNext = true
        for i in 0..<chars.count {
            let c = chars[i]
            if c.isLetter {
                if capitalizeNext {
                    chars[i] = Character(c.uppercased())
                }
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" {
                if i + 1 >= chars.count || chars[i + 1].isWhitespace {
                    capitalizeNext = true
                }
            }
        }
        return String(chars)
    }

    // MARK: - (f) terminal punctuation (tone-aware)

    private static func applyTerminalPunctuation(_ text: String, tone: ToneCategory) -> String {
        guard !text.isEmpty else { return text }

        // Messaging style: a short, single-sentence casual message drops its
        // trailing period instead of getting one appended.
        if tone == .casual, text.count < 120, isSingleSentence(text) {
            if text.hasSuffix("."), !text.hasSuffix("..") {
                return String(text.dropLast())
            }
            return text
        }

        if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
            return text
        }
        return text + "."
    }

    /// A terminal mark counts only if nothing but trailing whitespace/quotes follows it.
    private static func isSingleSentence(_ text: String) -> Bool {
        let terminals: Set<Character> = [".", "!", "?"]
        let chars = Array(text)
        for (idx, c) in chars.enumerated() where terminals.contains(c) {
            let rest = chars[(idx + 1)...]
            let isTrailing = rest.allSatisfy { $0.isWhitespace || $0 == "\"" || $0 == "'" }
            if !isTrailing { return false }
        }
        return true
    }

    // MARK: - shared regex replace helper

    /// Replaces every match of `pattern` with a fixed literal string (no
    /// capture-group templating), mirroring PersonalDictionaryStore's approach.
    private static func replaceAll(_ pattern: NSRegularExpression, in text: String, with replacement: String) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var output = ""
        var cursor = 0
        for match in matches {
            guard match.range.location >= cursor else { continue }
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += replacement
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }
}

/// Result of `RuleBasedFormatter.apply` -- the deterministic half of the pipeline.
struct RuleFormattingResult: Equatable {
    var text: String
    var pressEnter: Bool
    var corrections: Int
}
