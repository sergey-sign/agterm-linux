import agtermCore

@MainActor
extension AppController {
    func closeActiveSplit() {
        guard let id = store.selectedSessionID, let session = store.session(withID: id),
              session.hasSplit, !session.fullOverlayActive else { return }
        if session.scratchActive {
            store.toggleScratch(id)
            reconcile()
            return
        }
        store.closeSplit(id)
        reconcile()
        sessionFocusTarget(for: id, wantSplit: false)?.grabFocus(supersedingPopoverCapture: true)
    }

    @discardableResult
    func navigateWorkspace(_ direction: WorkspaceNavigation, userInitiated: Bool = true) -> WorkspaceStep? {
        if userInitiated { noteUserActivity() }
        guard let step = store.navigateWorkspace(direction) else { return nil }
        reconcile()
        syncSidebarSelection()
        return step
    }

    func toggleCurrentWorkspaceCollapse() {
        guard store.sidebarMode == .tree, let id = store.currentWorkspaceID else { return }
        store.setWorkspaceExpanded(id, expanded: store.isCurrentWorkspaceCollapsed)
        rebuildSidebarKeepingKeyboard()
    }
}
