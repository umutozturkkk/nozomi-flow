import Observation
import SwiftUI

/// Settings window shell: a fixed-width sidebar (System Settings-style icon
/// chips) driving a `Form`-based detail view per tab.
struct SettingsRootView: View {
    @Bindable var tabSelection: SettingsTabSelection
    let appState: AppState
    let settings: SettingsStore
    let dictionary: PersonalDictionaryStore
    let history: HistoryStore
    let permissions: PermissionsService
    let meetingStore: MeetingStore

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $tabSelection.tab) { tab in
                Label {
                    Text(tab.displayName)
                } icon: {
                    SettingsIconChip(systemName: tab.symbolName, tint: tab.tint)
                }
                .padding(.vertical, 3)
            }
            .navigationSplitViewColumnWidth(200)
            .listStyle(.sidebar)
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch tabSelection.tab {
        case .general:
            GeneralSettingsView(settings: settings)
        case .style:
            StyleSettingsView(settings: settings, appState: appState)
        case .dictionary:
            DictionarySettingsView(dictionary: dictionary)
        case .meetings:
            MeetingsSettingsView(store: meetingStore)
        case .history:
            HistorySettingsView(settings: settings, history: history)
        case .about:
            AboutSettingsView(appState: appState, permissions: permissions)
        }
    }
}
