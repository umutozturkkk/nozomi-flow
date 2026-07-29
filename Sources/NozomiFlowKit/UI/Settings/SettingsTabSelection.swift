import Observation
import SwiftUI

/// Backs the settings window's currently-selected sidebar tab.
/// `SettingsWindowController` mutates `tab` from `show(tab:)` (e.g. the
/// status-bar menu's "History…" item jumps straight to History without
/// rebuilding the window); `SettingsRootView`'s `NavigationSplitView`
/// selection binds to it directly via `@Bindable`.
@MainActor
@Observable
final class SettingsTabSelection {
    var tab: SettingsTab

    init(tab: SettingsTab = .general) {
        self.tab = tab
    }
}

/// Sidebar presentation metadata for each tab -- System Settings-style icon
/// chip (SF symbol + tint) plus its display label.
extension SettingsTab {
    var displayName: String { rawValue }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .style: return "wand.and.stars"
        case .dictionary: return "character.book.closed"
        case .meetings: return "person.2.wave.2"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .style: return .purple
        case .dictionary: return .orange
        case .meetings: return .teal
        case .history: return .blue
        case .about: return .indigo
        }
    }
}
