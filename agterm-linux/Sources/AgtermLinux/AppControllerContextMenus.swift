import CGtk
import Foundation
import agtermCore

/// Idle-deferred second half of `dismissContextMenu`: release the ref that kept the dismissed
/// popover's widget tree alive until the button-"clicked" emission that triggered the dismissal
/// fully unwound. Only the finalization is deferred — the unparent itself stays synchronous, since
/// `rebuildSidebar`'s remove-all loop cannot clear a listbox that still holds a popover child
/// (gtk_box_remove refuses non-layout children, and the `while first_child` loop then never ends).
private let onDeferredPopoverUnref: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    g_object_unref(data)
    return 0
}

/// Idle-deferred row context menu: when opening the menu rebuilt the sidebar (selecting a split
/// session focuses a pane → surfaceDidFocus → rebuildSidebar), the popup waits one idle cycle so
/// the fresh rows get laid out and mapped first.
private let onDeferredRowContextMenu: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().presentPendingRowContextMenu()
    }
    return 0
}

@MainActor
extension AppController {
    // MARK: - Row context menu

    @discardableResult
    func duplicateSession(_ id: UUID) -> Session? {
        noteUserActivity()
        guard let duplicate = store.duplicateSession(id) else { return nil }
        reconcile()
        return duplicate
    }

    func showRowContextMenu(listBox: OpaquePointer, x: Double, y: Double) {
        guard let rowPtr = gtk_list_box_get_row_at_y(listBox, Int32(y)),
              let sid = rowSession[OpaquePointer(rowPtr)] else { return }
        noteUserActivity()
        if !store.sidebarSelectionIDs.contains(sid) {
            store.selectSession(sid, sidebarSelection: [sid])
            sidebarSelectionAnchor = sid
            syncSidebarSelection()
            showActive()
        }
        // showActive's pane focus can SYNCHRONOUSLY rebuild the sidebar (focusing a split session's
        // pane → surfaceFocusEnter → surfaceDidFocus → rebuildSidebar), destroying the listBox and
        // row this gesture reported — using them is a use-after-free that crashes
        // gtk_widget_set_parent/popup. Re-resolve the session's LIVE row; and when the rebuild DID
        // happen (the live list box differs), the fresh rows have no layout yet, so a synchronous
        // popup anchors to a zero allocation on an unmapped parent and never appears — defer the
        // menu one idle cycle instead (idles run after GTK's layout/map phase).
        guard let liveRow = rowSession.first(where: { $0.value == sid })?.key,
              let liveListBox = gtk_widget_get_parent(W(liveRow)) else { return }
        if OpaquePointer(liveListBox) == listBox {
            presentRowContextMenu(sid: sid, anchorX: x)
        } else {
            pendingContextMenuSessionID = sid
            g_idle_add(onDeferredRowContextMenu, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func presentPendingRowContextMenu() {
        guard let sid = pendingContextMenuSessionID else { return }
        pendingContextMenuSessionID = nil
        presentRowContextMenu(sid: sid, anchorX: nil)
    }

    /// Build and pop up the row context menu for `sid`, parented to the session's CURRENT sidebar
    /// row's list box. `anchorX` keeps the click's horizontal position when known (the synchronous
    /// path); the deferred path passes nil and anchors near the row's leading edge.
    private func presentRowContextMenu(sid: UUID, anchorX: Double?) {
        guard let row = rowSession.first(where: { $0.value == sid })?.key,
              let listBox = gtk_widget_get_parent(W(row)) else { return }
        var rowAlloc = GtkAllocation()
        gtk_widget_get_allocation(W(row), &rowAlloc)
        // Tear down the previous popover before storing the replacement. Popping down a newly-created,
        // not-yet-mapped GtkPopover crashes inside gtk_popover_popdown.
        dismissContextMenu()
        contextMenuSession = sid
        guard let popover = op(gtk_popover_new()) else { return }
        attachControllerContext(to: popover, windowID: windowID)
        contextMenuPopover = popover
        gtk_widget_set_parent(W(popover), listBox)
        var rect = GdkRectangle(x: Int32(anchorX ?? Double(rowAlloc.x + 24)),
                                y: rowAlloc.y + rowAlloc.height / 2, width: 1, height: 1)
        gtk_popover_set_pointing_to(POPOVER(popover), &rect)
        gtk_popover_set_position(POPOVER(popover), GTK_POS_RIGHT)
        let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        let targets = store.sidebarSelectionTargets(forContextSession: sid)
        let sessions = targets.compactMap { store.session(withID: $0) }
        let suffix = targets.count > 1 ? " \(targets.count) Sessions" : ""
        addContextButton(box, sessions.allSatisfy(\.flagged) ? "Unflag\(suffix)" : "Flag\(suffix)",
                         unsafeBitCast(onCtxFlag as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        if targets.count == 1 {
            addContextButton(box, "Rename",
                             unsafeBitCast(onCtxRename as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
            addContextButton(box, "Duplicate Session",
                             unsafeBitCast(onCtxDuplicate as @convention(c) (OpaquePointer?, gpointer?) -> Void,
                                           to: GCallback.self))
            addContextButton(box, "Reveal in Files",
                             unsafeBitCast(onCtxRevealDirectory as @convention(c) (OpaquePointer?, gpointer?) -> Void,
                                           to: GCallback.self))
        }
        if sessions.contains(where: { $0.agentIndicator.status != .idle }) {
            addContextButton(box, "Clear Status\(suffix)",
                             unsafeBitCast(onCtxClearStatus as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        }
        if targets.count == 1 {
            addContextButton(box, "Focus Workspace",
                             unsafeBitCast(onCtxFocus as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        }
        for ws in store.workspaces where targets.contains(where: { store.workspace(forSession: $0)?.id != ws.id }) {
                if let btn = op(gtk_button_new_with_label("Move to \(ws.name)")) {
                    gtk_button_set_has_frame(BUTTON(btn), 0)
                    gtk_widget_set_halign(W(btn), GTK_ALIGN_FILL)
                    contextMoveTargets[btn] = ws.id
                    connect(btn, "clicked", unsafeBitCast(onCtxMove as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(btn))
                    gtk_box_append(cast(box), W(btn))
                }
        }
        addContextButton(box, targets.count > 1 ? "Close \(targets.count) Sessions" : "Close Session",
                         unsafeBitCast(onCtxClose as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        gtk_popover_set_child(POPOVER(popover), W(box))
        gtk_popover_popup(POPOVER(popover))
    }

    private func addContextButton(_ box: OpaquePointer?, _ label: String, _ handler: GCallback?) {
        guard let button = op(gtk_button_new_with_label(label)) else { return }
        gtk_button_set_has_frame(BUTTON(button), 0)
        gtk_widget_set_halign(W(button), GTK_ALIGN_FILL)
        connect(button, "clicked", handler)
        gtk_box_append(cast(box), W(button))
    }

    /// Pop down and unparent the menu NOW, but keep its widget tree ALIVE (one extra ref, released
    /// in an idle callback) until the current signal emission unwinds. Every menu item handler
    /// calls this from the "clicked" emission of a button INSIDE the popover; letting the unparent
    /// drop the last ref frees widgets that emission is still walking, which corrupts GTK's
    /// popover/grab bookkeeping — later menus silently fail to appear and a subsequent
    /// gtk_popover_popup crashes on freed memory. The unparent itself must stay synchronous:
    /// the same handlers trigger a sidebar rebuild whose remove-all loop spins forever on a
    /// listbox that still holds a popover child.
    func dismissContextMenu() {
        if let popover = contextMenuPopover {
            contextMenuPopover = nil
            _ = g_object_ref(RAW(popover))
            gtk_popover_popdown(POPOVER(popover))
            gtk_widget_unparent(W(popover))
            g_idle_add(onDeferredPopoverUnref, RAW(popover))
        }
        contextMoveTargets.removeAll()
    }

    func contextFocusWorkspace() {
        guard let id = contextMenuSession, let ws = store.workspace(forSession: id) else { return }
        dismissContextMenu()
        focusWorkspace(store.focusedWorkspaceID == ws.id ? nil : ws.id)
    }

    func contextMoveToWorkspace(_ data: gpointer?) {
        guard let data, let ws = contextMoveTargets[OpaquePointer(data)], let id = contextMenuSession else { return }
        let targets = store.sidebarSelectionTargets(forContextSession: id)
        dismissContextMenu()
        store.moveSessions(targets, toWorkspace: ws)
        reconcile()
    }

    func contextFlag() {
        guard let id = contextMenuSession else { return }
        let targets = store.sidebarSelectionTargets(forContextSession: id)
        let allFlagged = targets.compactMap { store.session(withID: $0) }.allSatisfy(\.flagged)
        dismissContextMenu()
        store.setFlag(!allFlagged, forSessions: targets)
        rebuildSidebar()
    }

    func contextRename() {
        guard let id = contextMenuSession else { return }
        dismissContextMenu()
        selectSession(id)
        startRenameActive()
    }

    func contextDuplicate() {
        guard let id = contextMenuSession else { return }
        dismissContextMenu()
        _ = duplicateSession(id)
    }

    func contextRevealDirectory() {
        guard let id = contextMenuSession else { return }
        dismissContextMenu()
        if !revealSessionDirectory(id) { showToast("Session directory is no longer available") }
    }

    func showWorkspaceContextMenu(_ rowData: gpointer?, x: Double, y: Double) {
        guard let rowData, let wsID = workspaceDiscButtons[OpaquePointer(rowData)] else { return }
        let parent = OpaquePointer(rowData)
        // See showRowContextMenu: the old popover must be dismissed before the new one is registered.
        dismissContextMenu()
        contextMenuWorkspace = wsID
        guard let popover = op(gtk_popover_new()) else { return }
        attachControllerContext(to: popover, windowID: windowID)
        contextMenuPopover = popover
        gtk_widget_set_parent(W(popover), W(parent))
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(POPOVER(popover), &rect)
        gtk_popover_set_position(POPOVER(popover), GTK_POS_RIGHT)
        let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        addContextButton(box, "Rename", unsafeBitCast(onCtxWorkspaceRename as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        if store.canRemoveWorkspace {
            addContextButton(box, "Delete Workspace", unsafeBitCast(onCtxWorkspaceDelete as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        }
        gtk_popover_set_child(POPOVER(popover), W(box))
        gtk_popover_popup(POPOVER(popover))
    }

    func contextWorkspaceRename() {
        guard let id = contextMenuWorkspace else { return }
        dismissContextMenu()
        beginRename(id: id, isWorkspace: true)
    }

    func contextWorkspaceDelete() {
        guard let id = contextMenuWorkspace, store.canRemoveWorkspace else { return }
        dismissContextMenu()
        pendingDeleteWorkspace = id
        let ws = store.workspaces.first(where: { $0.id == id })
        let heading = "Delete Workspace?"
        let body = DeletePrompt.workspaceMessage(name: ws?.name ?? "this workspace", sessions: ws?.sessions.count ?? 0)
        let dialog = OpaquePointer(heading.withCString { h in body.withCString { b in adw_alert_dialog_new(h, b) } })
        attachControllerContext(to: dialog, windowID: windowID)
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "delete".withCString { i in "Delete".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "delete".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_DESTRUCTIVE) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onDeleteWorkspaceResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    func confirmWorkspaceDelete(_ response: String) {
        defer { pendingDeleteWorkspace = nil }
        guard response == "delete", let id = pendingDeleteWorkspace, store.canRemoveWorkspace else { return }
        store.removeWorkspace(id)
        reconcile()
    }

    func confirmDeleteWindow(_ id: UUID) {
        guard gLibrary.canRemoveWindow else { return }
        pendingDeleteWindow = id
        let name = gLibrary.windows.first(where: { $0.id == id })?.name ?? "this window"
        let dialog = OpaquePointer("Delete Window?".withCString { h in DeletePrompt.windowMessage(name: name).withCString { b in adw_alert_dialog_new(h, b) } })
        attachControllerContext(to: dialog, windowID: windowID)
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "delete".withCString { i in "Delete".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "delete".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_DESTRUCTIVE) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onDeleteWindowResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    func confirmWindowDelete(_ response: String) {
        defer { pendingDeleteWindow = nil }
        guard response == "delete", let id = pendingDeleteWindow, gLibrary.canRemoveWindow else { return }
        if let ctl = gWindows[id] {
            ctl.confirmedClose = true
            gtk_window_close(WIN(ctl.windowPointer))
        }
        gLibrary.removeWindow(id)
    }

    func renameWindowDialog(_ id: UUID) {
        pendingRenameWindow = id
        let cur = gLibrary.windows.first(where: { $0.id == id })?.name ?? ""
        let dialog = OpaquePointer("Rename Window".withCString { adw_alert_dialog_new($0, nil) })
        attachControllerContext(to: dialog, windowID: windowID)
        let entry = OpaquePointer(gtk_entry_new())
        cur.withCString { gtk_editable_set_text(entry, $0) }
        pendingRenameEntry = entry
        adw_alert_dialog_set_extra_child(cast(dialog), W(entry))
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "rename".withCString { i in "Rename".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "rename".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_SUGGESTED) }
        "rename".withCString { adw_alert_dialog_set_default_response(cast(dialog), $0) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onRenameWindowResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    func confirmWindowRename(_ response: String) {
        defer { pendingRenameWindow = nil; pendingRenameEntry = nil }
        guard response == "rename", let id = pendingRenameWindow, let entry = pendingRenameEntry,
              let cstr = gtk_editable_get_text(entry) else { return }
        let name = String(cString: cstr).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        gLibrary.renameWindow(id, to: name)
        if id == windowID { updateTitle() }
    }

    func contextClearStatus() {
        guard let id = contextMenuSession else { return }
        let targets = store.sidebarSelectionTargets(forContextSession: id)
        dismissContextMenu()
        for target in targets { store.setAgentIndicator(AgentIndicator(), forSession: target) }
        rebuildSidebar()
    }

    func contextCloseSession() {
        guard let id = contextMenuSession else { return }
        let targets = store.sidebarSelectionTargets(forContextSession: id)
        dismissContextMenu()
        guard targets.count > 1 else {
            requestCloseSession(id, closingCoversFirst: false)
            return
        }
        if linuxSettingsStore().load().closeGraceUndoEnabled ?? true {
            if store.softCloseSessions(targets) { reconcileSoftClose(preserving: targets) }
        } else {
            for target in targets { store.closeSession(target) }
            reconcile()
        }
    }
}
