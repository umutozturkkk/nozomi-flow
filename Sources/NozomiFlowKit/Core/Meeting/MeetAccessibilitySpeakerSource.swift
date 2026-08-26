import Foundation
import AppKit
import ApplicationServices

/// Reads who is speaking out of a browser's accessibility tree.
///
/// Google Meet already renders the answer: its captions are labelled with the
/// speaker's name, because captions are an accessibility feature and Google built
/// them for screen readers. Reading them costs no permission this app does not
/// already hold, no video frames, and no provider.
///
/// Everything here is best effort by design. A meeting that records without speaker
/// names is still a good meeting, so every failure logs once and leaves the session
/// on the plain two-track transcript rather than interrupting a call in progress.
final class MeetAccessibilitySpeakerSource: MeetingSpeakerSource, @unchecked Sendable {

    var onCaption: ((CaptionObservation) -> Void)?
    var onRoster: (([String]) -> Void)?

    /// Once a second. Captions update several times a second, but the timeline only
    /// needs to know who is talking, and re-reading a subtree costs real IPC.
    private let pollInterval: TimeInterval = 1.0
    /// A failed lookup re-walks the whole document, which is expensive, so it is not
    /// attempted on every tick.
    private let relocateInterval: TimeInterval = 5.0
    /// The roster costs the same full walk, and people join a call at human speed.
    private let rosterInterval: TimeInterval = 30.0

    private let queue = DispatchQueue(label: "co.nozomi.flow.meet-speaker", qos: .utility)
    private var timer: DispatchSourceTimer?

    private var parser = MeetCaptionParser()
    private var application: AXUIElement?
    private var captionContainer: AXUIElement?
    private var lastRelocateAttempt = Date.distantPast
    private var lastRosterRead = Date.distantPast
    private var reportedRoster: [String] = []
    private var loggedMissingCaptions = false

    // MARK: - Lifecycle

    func start() async throws {
        guard AXIsProcessTrusted() else { throw MeetingSpeakerSourceError.accessibilityDenied }
        guard let browser = Self.runningBrowser() else { throw MeetingSpeakerSourceError.noSupportedBrowser }

        let application = AXUIElementCreateApplication(browser.processIdentifier)
        // Chromium hosts expose web content to the accessibility tree only once a
        // client asks for it. Without this the tree stops at the window frame and
        // nothing below is ever visible.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        queue.sync { self.application = application }
        Log.audio.info("meet speaker source attached to \(browser.bundleIdentifier ?? "browser")")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Chromium needs a moment to build the tree after being asked for it.
        timer.schedule(deadline: .now() + 2.0, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            application = nil
            captionContainer = nil
            parser = MeetCaptionParser()
            reportedRoster = []
        }
    }

    // MARK: - Polling

    private func tick() {
        guard let application else { return }
        let now = Date()

        // Independent of the caption lookup: people join a call after it starts, and
        // a roster that was read once at the beginning would miss them.
        if now.timeIntervalSince(lastRosterRead) >= rosterInterval {
            lastRosterRead = now
            readRoster(from: application)
        }

        if captionContainer == nil {
            guard now.timeIntervalSince(lastRelocateAttempt) >= relocateInterval else { return }
            lastRelocateAttempt = now
            captionContainer = Self.findCaptionContainer(in: application)

            if captionContainer == nil {
                if !loggedMissingCaptions {
                    loggedMissingCaptions = true
                    Log.audio.info("no meet caption region in the accessibility tree yet")
                }
                return
            }
            Log.audio.info("meet caption region located")
        }

        guard let container = captionContainer else { return }
        let lines = Self.text(under: container, budget: 400)
        guard !lines.isEmpty else {
            // A cached element that has stopped answering means the call ended, the
            // tab changed, or Meet rebuilt its DOM. Drop it and look again.
            if Self.title(of: container) == nil { captionContainer = nil }
            return
        }

        for observation in parser.ingest(lines.joined(separator: "\n"), at: now) {
            onCaption?(observation)
        }
    }

    private func readRoster(from application: AXUIElement) {
        let names = Self.findRoster(in: application)
        guard !names.isEmpty, names != reportedRoster else { return }
        reportedRoster = names
        onRoster?(names)
    }

    // MARK: - Locating

    /// First supported browser that is running. Meet has no native app, so a call is
    /// always in one of these.
    static func runningBrowser() -> NSRunningApplication? {
        let identifiers = [
            "com.google.Chrome",
            "com.brave.Browser",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "com.apple.Safari",
        ]
        for identifier in identifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                return app
            }
        }
        return nil
    }

    /// Finds the element whose subtree holds the caption lines.
    ///
    /// Two strategies, tried in order, because which one Meet actually satisfies is
    /// the one thing about this feature that could not be verified without a live
    /// call. The log line above says which one won, so the first real meeting settles
    /// it and the loser can be deleted.
    ///
    /// 1. A live region, which is how a caption area announces itself to a screen
    ///    reader, whose subtree already parses as captions.
    /// 2. An element labelled as captions in its own right.
    static func findCaptionContainer(in application: AXUIElement) -> AXUIElement? {
        var budget = 20_000
        if let live = firstElement(under: application, budget: &budget, maximumDepth: 60, matches: {
            hasAttribute($0, "AXARIALive") && containsCaptionLine($0)
        }) {
            return live
        }

        budget = 20_000
        return firstElement(under: application, budget: &budget, maximumDepth: 60, matches: { element in
            guard let label = descriptiveText(element)?.lowercased() else { return false }
            guard captionVocabulary.contains(where: label.contains) else { return false }
            return containsCaptionLine(element)
        })
    }

    /// Participant names from the panel, when the user happens to have it open.
    ///
    /// Never opened on their behalf: moving someone's UI during their own call is not
    /// a trade this feature gets to make. With the panel closed the roster falls back
    /// to whoever the captions named, which covers everyone who actually spoke.
    static func findRoster(in application: AXUIElement) -> [String] {
        var budget = 20_000
        let list = firstElement(under: application, budget: &budget, maximumDepth: 60, matches: { element in
            guard role(of: element) == kAXListRole as String else { return false }
            guard let label = descriptiveText(element)?.lowercased() else { return false }
            return rosterVocabulary.contains(where: label.contains)
        })
        guard let list else { return [] }

        return children(list)
            .compactMap { descriptiveText($0) }
            .map { Self.stripRoleSuffix($0) }
            .filter { !$0.isEmpty && $0.count <= MeetCaptionParser.maximumNameLength }
    }

    /// Meet appends status to a participant row, as in "Ahmet (Host)" or
    /// "Ahmet, presenting". The name is what the transcript needs.
    static func stripRoleSuffix(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" (", ", "] {
            if let range = name.range(of: separator) {
                name = String(name[name.startIndex..<range.lowerBound])
            }
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let captionVocabulary = ["caption", "subtitle", "altyaz"]
    private static let rosterVocabulary = ["participant", "people", "katılımcı", "katilimci", "kişiler"]

    private static func containsCaptionLine(_ element: AXUIElement) -> Bool {
        text(under: element, budget: 120).contains { MeetCaptionParser.parseLine($0) != nil }
    }

    // MARK: - Accessibility plumbing

    /// Depth-first search bounded by a node budget and a depth cap, so a document
    /// that is larger or deeper than expected costs a slow tick rather than a hang.
    static func firstElement(
        under root: AXUIElement,
        budget: inout Int,
        maximumDepth: Int,
        matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard budget > 0, maximumDepth > 0 else { return nil }
        budget -= 1
        if matches(root) { return root }
        for child in children(root) {
            if let found = firstElement(
                under: child, budget: &budget, maximumDepth: maximumDepth - 1, matches: matches) {
                return found
            }
            if budget <= 0 { return nil }
        }
        return nil
    }

    /// Every string an element's subtree carries, in document order.
    static func text(under root: AXUIElement, budget: Int) -> [String] {
        var remaining = budget
        var collected: [String] = []

        func visit(_ element: AXUIElement) {
            guard remaining > 0 else { return }
            remaining -= 1
            if let text = descriptiveText(element) { collected.append(text) }
            for child in children(element) {
                visit(child)
                if remaining <= 0 { return }
            }
        }

        visit(root)
        return collected
    }

    static func descriptiveText(_ element: AXUIElement) -> String? {
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = string(element, attribute as String), !text.isEmpty { return text }
        }
        return nil
    }

    static func title(of element: AXUIElement) -> String? {
        string(element, kAXTitleAttribute as String) ?? string(element, kAXRoleAttribute as String)
    }

    static func role(of element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute as String)
    }

    static func hasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let raw = value as? [AXUIElement]
        else { return [] }
        return raw
    }
}
