import Foundation

/// Mirrors one remote tmux session into a dedicated cmux sidebar workspace.
///
/// Owns the binding between a ``RemoteTmuxControlConnection`` and a ``Workspace``:
/// each tmux window becomes a tab (rendering that window's first pane via a
/// MANUAL-I/O display surface), pane output is routed to the right tab, and the
/// workspace's default local terminal tab is closed once remote tabs exist.
///
/// Full pane→split mapping and window-close handling build on this first
/// session→workspace increment.
@MainActor
final class RemoteTmuxSessionMirror {
    let host: RemoteTmuxHost
    private(set) var sessionName: String
    let connection: RemoteTmuxControlConnection

    /// Updates the tracked session name after a `rename-session`.
    func setSessionName(_ name: String) { sessionName = name }

    private weak var workspace: Workspace?
    private let defaultPanelIds: [UUID]
    private var defaultClosed = false
    private var panelIdByWindow: [Int: UUID] = [:]
    private var panelIdByPane: [Int: UUID] = [:]
    /// Last-known working directory per tmux pane, so switching the active pane of
    /// a multi-pane window can re-project that pane's directory onto the tab.
    private var cwdByPane: [Int: String] = [:]
    /// Per-window multi-pane renderers (present once a window has >1 pane).
    private var windowMirrorByWindowId: [Int: RemoteTmuxWindowMirror] = [:]
    private var observerToken: RemoteTmuxControlConnection.ObserverToken?
    /// Initial client-sizing retry; see ``scheduleInitialClientSizing()``.
    private var initialSizingTask: Task<Void, Never>?
    /// Re-arm the initial sizing when one of this workspace's surfaces becomes
    /// ready / enters a window: a background workspace's surfaces may not even
    /// EXIST while the rebuild-time retry runs (they are created when the
    /// workspace is first shown), so that retry alone could expire and leave the
    /// remote at ssh's default 80×24. Removed in ``detachObserver()``.
    private var surfaceReadyObservers: [NSObjectProtocol] = []

    init(
        host: RemoteTmuxHost,
        sessionName: String,
        connection: RemoteTmuxControlConnection,
        workspace: Workspace
    ) {
        self.host = host
        self.sessionName = sessionName
        self.connection = connection
        self.workspace = workspace
        self.defaultPanelIds = Array(workspace.panels.keys)

        // Register as one of possibly several observers — never overwrite a
        // single shared closure on the connection.
        self.observerToken = connection.addObserver(
            onPaneOutput: { [weak self] paneId, data in
                self?.routeOutput(paneId: paneId, data: data)
            },
            onPaneCwd: { [weak self] paneId, path in
                self?.handlePaneCwd(paneId: paneId, path: path)
            },
            onPaneReflow: { [weak self] paneId, noReflow, command in
                self?.handlePaneReflow(paneId: paneId, noReflow: noReflow, command: command)
            },
            onActivePaneChanged: { [weak self] windowId, paneId in
                self?.handleActivePaneChanged(windowId: windowId, paneId: paneId)
            },
            onTopologyChanged: { [weak self] in
                self?.rebuild()
            },
            onExit: { [weak self] in
                self?.handleConnectionExited()
            }
        )
        rebuild()
        installSurfaceReadinessObservers(workspaceId: workspace.id)
    }

    /// Observes surface readiness/window-attachment for this workspace and re-arms
    /// ``scheduleInitialClientSizing()`` — the sizing only succeeds once a surface
    /// is live and in a window, which for a background workspace happens long
    /// after `rebuild()`. Same observation pattern as
    /// `BackgroundWorkspacePrimeCoordinator.installReadinessObservers`.
    private func installSurfaceReadinessObservers(workspaceId: UUID) {
        let names: [Notification.Name] = [
            .terminalSurfaceDidBecomeReady, .terminalSurfaceHostedViewDidMoveToWindow,
        ]
        for name in names {
            surfaceReadyObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                      readyWorkspaceId == workspaceId else { return }
                Task { @MainActor in self?.scheduleInitialClientSizing() }
            })
        }
    }

    /// The remote session ended for good (its last tmux window was killed, it was
    /// killed out-of-band, or a reconnect found it gone) — hand off to the controller
    /// to remove the mirror and close the now-dead workspace. A transient transport
    /// loss does NOT reach here (the connection reconnects); deliberate detach / quit
    /// / window close suppress `onExit`. So this only runs for genuine remote ends.
    private func handleConnectionExited() {
        guard let workspaceId = mirroredWorkspaceId else { return }
        AppDelegate.shared?.remoteTmuxController.handleSessionEndedRemotely(
            host: host, sessionName: sessionName, workspaceId: workspaceId
        )
    }

    /// The cmux workspace mirroring this session (if still alive).
    var mirroredWorkspaceId: UUID? { workspace?.id }

    /// The tmux window id whose mirrored tab is backed by `panelId`, if any.
    func windowId(forPanel panelId: UUID) -> Int? {
        panelIdByWindow.first(where: { $0.value == panelId })?.key
    }

    /// Deregisters this mirror's connection observer and tears down all per-window
    /// multi-pane renderers (called when the mirror is torn down so its callbacks
    /// don't linger on a shared connection and its pane surfaces don't leak).
    func detachObserver() {
        initialSizingTask?.cancel()
        initialSizingTask = nil
        for observer in surfaceReadyObservers { NotificationCenter.default.removeObserver(observer) }
        surfaceReadyObservers.removeAll()
        if let observerToken {
            connection.removeObserver(observerToken)
            self.observerToken = nil
        }
        for mirror in windowMirrorByWindowId.values {
            workspace?.setRemoteTmuxWindowMirror(nil, forPanelId: mirror.panelId)
            mirror.teardown()
        }
        windowMirrorByWindowId.removeAll()
    }

    /// The tmux window id (if any) whose layout currently contains `paneId`.
    private func windowIdContaining(pane paneId: Int) -> Int? {
        connection.windowsByID.first(where: { $0.value.paneIDsInOrder.contains(paneId) })?.key
    }

    /// Adds a tab for any window that doesn't yet have one, refreshes existing
    /// tab titles after a tmux rename, activates/reconciles the in-tab multi-pane
    /// renderer for multi-pane windows, then closes the workspace's original
    /// local tab(s) once at least one remote tab exists.
    func rebuild() {
        guard let workspace else { return }
        var createdNewPanel = false
        for windowId in connection.windowOrder {
            guard let window = connection.windowsByID[windowId],
                  let firstPaneId = window.paneIDsInOrder.first else { continue }
            let title = Self.tabTitle(for: window)
            let panelId: UUID
            if let existing = panelIdByWindow[windowId] {
                // Existing tab — refresh its title if tmux renamed the window.
                workspace.updateRemoteTmuxTabTitle(panelId: existing, title: title)
                panelId = existing
            } else {
                guard let panel = workspace.addRemoteTmuxDisplayPane(
                    remotePaneId: firstPaneId,
                    title: title,
                    focus: false,
                    onInput: { [weak connection] data in
                        Task { @MainActor in connection?.sendKeys(paneId: firstPaneId, data: data) }
                    },
                    // Size the remote tmux client to the rendered grid so a single-
                    // pane window (the common case — where a claude / claude agents
                    // TUI runs) doesn't stay at ssh's default 80×24 and render
                    // mangled. The multi-pane path handles this via the window
                    // mirror's own geometry.
                    onResize: { [weak connection] columns, rows in
                        connection?.setClientSize(columns: columns, rows: rows)
                    }
                ) else { continue }
                panelIdByWindow[windowId] = panel.id
                panelIdByPane[firstPaneId] = panel.id
                connection.seedPane(paneId: firstPaneId)
                panelId = panel.id
                createdNewPanel = true
            }
            reconcileWindowMirror(windowId: windowId, panelId: panelId, window: window, in: workspace)
        }
        if createdNewPanel { scheduleInitialClientSizing() }
        // Close tabs for windows tmux removed, so a closed remote window doesn't
        // leave a frozen tab behind.
        let liveWindows = Set(connection.windowOrder)
        for (windowId, panelId) in panelIdByWindow where !liveWindows.contains(windowId) {
            if let mirror = windowMirrorByWindowId[windowId] {
                workspace.setRemoteTmuxWindowMirror(nil, forPanelId: panelId)
                mirror.teardown()
                windowMirrorByWindowId[windowId] = nil
            }
            _ = workspace.closePanel(panelId, force: true)
            panelIdByWindow[windowId] = nil
            panelIdByPane = panelIdByPane.filter { $0.value != panelId }
        }
        // Drop cached directories for panes tmux no longer reports, so the cache
        // stays bounded across window/pane churn (tmux pane ids never recur).
        let livePanes = Set(connection.windowsByID.values.flatMap { $0.paneIDsInOrder })
        cwdByPane = cwdByPane.filter { livePanes.contains($0.key) }
        // Settle OSC-title ownership against the fresh topology (see the "OSC
        // title lifetime" section). Sends fire only while the name WE sent is
        // still current — an out-of-band rename from another client wins.
        // Iterate a snapshot: both branches mutate the map via setOSCTitleOwner.
        let ownerSnapshot = oscTitleOwnerByWindow
        for (windowId, owner) in ownerSnapshot {
            let paneStillInWindow =
                connection.windowsByID[windowId]?.paneIDsInOrder.contains(owner.paneId) == true
            if !paneStillInWindow {
                // The titling pane died — or was moved/joined into ANOTHER
                // window — without ever classifying back to a shell, so the
                // restore path (which resolves a pane to its CURRENT window)
                // can never settle this entry. Drop it here.
                setOSCTitleOwner(windowId: windowId, to: nil)
                if connection.windowsByID[windowId]?.name == owner.name {
                    sendAutomaticNamingRestore(
                        windowId: windowId,
                        command: lastReflowByPane[owner.paneId]?.command ?? ""
                    )
                }
                continue
            }
            // Deferred-restore retry: the restore was skipped because our
            // rename's %window-renamed echo hadn't landed when the shell
            // classification arrived — that echo itself triggers this rebuild.
            guard let reflow = lastReflowByPane[owner.paneId], !reflow.noReflow,
                  connection.windowsByID[windowId]?.name == owner.name else { continue }
            setOSCTitleOwner(windowId: windowId, to: nil)
            sendAutomaticNamingRestore(windowId: windowId, command: reflow.command)
        }
        pendingSurfaceTitleByWindow = pendingSurfaceTitleByWindow.filter { liveWindows.contains($0.key) }
        lastReflowByPane = lastReflowByPane.filter { livePanes.contains($0.key) }
        reflowRequeryAt = reflowRequeryAt.filter { livePanes.contains($0.key) }
        closeDefaultTabsIfNeeded()
        // Follow out-of-band tmux window reorders (a second client, or a manual
        // move-window / a new-window inserted mid-list): the cmux tabs are created
        // in arrival order and appended, so a non-tail change leaves the strip
        // stale. Reorder to match tmux's reported order, preserving focus. The
        // cmux→tmux drag direction is handled by handleMirrorWindowsReordered and
        // already matches, so this no-ops there.
        let desiredPanelOrder = connection.windowOrder.compactMap { panelIdByWindow[$0] }
        if desiredPanelOrder.count > 1 {
            workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder: desiredPanelOrder)
        }
    }

    /// Brief retry that sizes the remote tmux client to a single-pane tab's
    /// rendered grid on attach. Needed because `createSurface` stamps the final
    /// grid before the tab is on screen, and `TerminalSurface.updateSize` only
    /// reports grid CHANGES — so without an initial push the remote would stay at
    /// ssh's default 80×24 (mangling TUIs) until the user resizes the window.
    /// This is the single-pane analogue of the multi-pane path's
    /// `RemoteTmuxWindowMirrorView.scheduleClientSize` (same shape: one synchronous
    /// attempt, then a sleep-first retry). One push from the first on-screen
    /// surface suffices (the tmux client has a single size); live resizes
    /// afterwards flow through the panel's `onResize` hook. Re-armed by the
    /// surface-readiness observers whenever a surface becomes displayable, so a
    /// background workspace is sized when first shown even though this retry
    /// budget expired long before.
    private func scheduleInitialClientSizing() {
        initialSizingTask?.cancel()
        if pushInitialClientSize() { return }
        initialSizingTask = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self else { return }
                if self.pushInitialClientSize() { return }
            }
        }
    }

    /// One initial-sizing attempt. Returns `true` when there is nothing (more) to
    /// do: the size was pushed from the first single-pane surface with an
    /// on-screen grid, or no single-pane window remains to size (multi-pane
    /// windows are skipped — their mirror view owns client sizing).
    private func pushInitialClientSize() -> Bool {
        guard let workspace else { return true }
        let singlePanePanelIds = panelIdByWindow
            .filter { windowMirrorByWindowId[$0.key] == nil }
            .values
        guard !singlePanePanelIds.isEmpty else { return true }
        for panelId in singlePanePanelIds {
            guard let panel = workspace.panels[panelId] as? TerminalPanel,
                  let grid = panel.surface.renderedGridCells() else { continue }
            connection.setClientSize(columns: grid.columns, rows: grid.rows)
            return true
        }
        return false
    }

    /// Creates the in-tab multi-pane renderer the first time a window has more
    /// than one pane, and reconciles it on subsequent layout changes. Once
    /// created it persists for that window (rendering even a single pane), so the
    /// tab never flips back and forth between the two render paths.
    private func reconcileWindowMirror(
        windowId: Int,
        panelId: UUID,
        window: RemoteTmuxWindow,
        in workspace: Workspace
    ) {
        if let mirror = windowMirrorByWindowId[windowId] {
            mirror.reconcile(layout: window.layout)
            return
        }
        guard window.paneIDsInOrder.count > 1 else { return }
        let mirror = RemoteTmuxWindowMirror(
            windowId: windowId,
            panelId: panelId,
            connection: connection,
            layout: window.layout,
            makePanel: { [weak workspace, weak connection] tmuxPaneId in
                workspace?.makeRemoteTmuxPanePanel(onInput: { data in
                    Task { @MainActor in connection?.sendKeys(paneId: tmuxPaneId, data: data) }
                })
            }
        )
        windowMirrorByWindowId[windowId] = mirror
        workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: panelId)
        // The window mirror now owns client sizing for this window (it sends
        // refresh-client -C for the whole multi-pane area). Clear the original
        // single-pane display surface's resize hook so both paths don't drive the
        // same connection with differently-computed sizes.
        if let panel = workspace.panels[panelId] as? TerminalPanel {
            panel.surface.onManualGridResize = nil
        }
    }

    /// The tab title for a mirrored window: the tmux window name, or a localized
    /// placeholder when tmux hasn't reported one. tmux window names are
    /// content-derived (like every other cmux tab title) so the name itself is
    /// not translated; only the empty-name placeholder is localized.
    private static func tabTitle(for window: RemoteTmuxWindow) -> String {
        let trimmed = window.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            ? String(localized: "remoteTmux.tab.window", defaultValue: "tmux window")
            : trimmed
    }

    private func closeDefaultTabsIfNeeded() {
        guard !defaultClosed, !panelIdByWindow.isEmpty, let workspace else { return }
        for panelId in defaultPanelIds where workspace.panels[panelId] != nil {
            _ = workspace.closePanel(panelId, force: true)
        }
        defaultClosed = true
    }

    /// Routes a pane's reported working directory to the tab that renders it: a
    /// single-pane window updates its display tab; a multi-pane window updates its
    /// window tab only when the reporting pane is the window's active pane, so a
    /// background pane's `cd` can't hijack the tab's folder. No-ops for unknown panes.
    private func handlePaneCwd(paneId: Int, path: String) {
        guard let workspace else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cwdByPane[paneId] = trimmed
        guard let panelId = tabPanelId(forPane: paneId) else { return }
        // Multi-pane window: only the active pane represents the tab.
        if let windowId = windowIdContaining(pane: paneId),
           windowMirrorByWindowId[windowId] != nil,
           activePane(inWindow: windowId) != paneId {
            return
        }
        _ = workspace.updatePanelDirectory(panelId: panelId, directory: trimmed)
    }

    /// Re-projects the newly-active pane's cached directory onto its multi-pane
    /// window tab when the active pane changes, so switching panes updates the
    /// folder immediately (rather than waiting for that pane's next `cd`).
    private func handleActivePaneChanged(windowId: Int, paneId: Int) {
        guard let workspace,
              windowMirrorByWindowId[windowId] != nil,
              let panelId = panelIdByWindow[windowId],
              let path = cwdByPane[paneId] else { return }
        _ = workspace.updatePanelDirectory(panelId: panelId, directory: path)
    }

    /// The panel id of the tab that renders `paneId`: a single-pane window's
    /// display tab, or a multi-pane window's window tab.
    private func tabPanelId(forPane paneId: Int) -> UUID? {
        panelIdByPane[paneId] ?? windowIdContaining(pane: paneId).flatMap { panelIdByWindow[$0] }
    }

    /// The pane that currently represents `windowId`'s tab: the user-focused mirror
    /// pane, else tmux's active pane, else the window's first pane.
    private func activePane(inWindow windowId: Int) -> Int? {
        windowMirrorByWindowId[windowId]?.activePaneId
            ?? connection.activePaneByWindow[windowId]
            ?? connection.windowsByID[windowId]?.paneIDsInOrder.first
    }

    private func routeOutput(paneId: Int, data: Data) {
        // Exit probe for a pane that owns its window's OSC title: the shell
        // prompt printed after the TUI dies is itself output, so a throttled
        // classification re-pull here is what detects the exit on tmux builds
        // whose `-B` subscription never delivers the change. O(1) set test for
        // every other pane.
        if ownedTitlePaneIds.contains(paneId) { requeryReflow(paneId: paneId) }
        // Multi-pane window: its in-tab renderer owns the pane's surface.
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            mirror.routeOutput(paneId: paneId, data: data)
            return
        }
        // Single-pane window: route to the window-tab's panel surface.
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return }
        panel.surface.processRemoteOutput(data)
    }

    // MARK: - OSC title lifetime
    //
    // A TUI's OSC title is mirrored to the tmux window name with rename-window,
    // which also turns the window's `automatic-rename` off. When the titling
    // pane returns to a plain shell, naming is handed back to tmux: rename to
    // the just-classified shell command — tmux recomputes automatic names
    // LAZILY (only on pane activity AFTER the option changes), so an idle pane
    // would otherwise keep the dead TUI's name — then unset the window-local
    // `automatic-rename` override so later command changes rename
    // automatically again (a user's global automatic-rename choice is
    // respected). Explicit tab renames pin the name instead (plain tmux
    // semantics, ``noteWindowNamePinned(windowId:)``), and an out-of-band
    // rename from another client always wins: restores fire only while the
    // name WE sent is still the window's current one.
    //
    // The `-B` subscription doesn't deliver classification CHANGES on all tmux
    // builds (see ``RemoteTmuxControlConnection/subscribePaneReflow(paneId:)``),
    // so edges are re-pulled with the always-working one-shot query: a title
    // arriving against a (possibly stale seed-time) "shell" classification is
    // HELD and replayed against the fresh result, and a pane owning its
    // window's title gets a throttled exit probe on output — the shell prompt
    // printed after the TUI dies is itself output. All of it is best-effort:
    // an edge missed entirely settles at the next reconnect (seedPane
    // re-queries every pane) via the rebuild() ownership sweep.
    //
    // State (keyed by tmux window/pane id, pruned in `rebuild()`):
    //   oscTitleOwnerByWindow  windowId → (titling pane, the name WE sent,
    //     sawNameMismatch). Recorded only after an actual send. One name
    //     mismatch at restore time is tolerated (usually our own rename's
    //     %window-renamed echo still in flight); a second consecutive one
    //     means another client renamed the window → ownership dropped.
    //   ownedTitlePaneIds  derived pane-id projection of the owner map, so
    //     ``routeOutput(paneId:data:)``'s exit probe is an O(1) set test.
    //   pendingSurfaceTitleByWindow  the held title awaiting a fresh
    //     classification (replayed or dropped in ``handlePaneReflow``).
    //   lastReflowByPane  last classification + `pane_current_command`: the
    //     sync gate and the rebuild sweep need the CURRENT state (the events
    //     are edges), and the restore renames to the cached command.
    //   reflowRequeryAt  per-pane throttle for the one-shot re-pull.

    /// Mutate via ``setOSCTitleOwner(windowId:to:)`` (keeps
    /// ``ownedTitlePaneIds`` in sync and resets `sawNameMismatch`) — the one
    /// deliberate exception is the strike write in
    /// ``restoreAutomaticRenameIfNeeded(paneId:noReflow:command:)``.
    private var oscTitleOwnerByWindow: [Int: (paneId: Int, name: String, sawNameMismatch: Bool)] = [:]
    private var ownedTitlePaneIds: Set<Int> = []
    private var pendingSurfaceTitleByWindow: [Int: String] = [:]
    private var lastReflowByPane: [Int: (noReflow: Bool, command: String)] = [:]
    private var reflowRequeryAt: [Int: Date] = [:]
    private static let reflowRequeryInterval: TimeInterval = 2

    private func setOSCTitleOwner(windowId: Int, to owner: (paneId: Int, name: String)?) {
        oscTitleOwnerByWindow[windowId] = owner.map { ($0.paneId, $0.name, false) }
        ownedTitlePaneIds = Set(oscTitleOwnerByWindow.values.map(\.paneId))
    }

    /// Re-pulls a pane's reflow classification via the one-shot query,
    /// throttled (see the section comment for why polling edges is needed).
    private func requeryReflow(paneId: Int) {
        let now = Date()
        if let last = reflowRequeryAt[paneId],
           now.timeIntervalSince(last) < Self.reflowRequeryInterval { return }
        reflowRequeryAt[paneId] = now
        connection.requestPaneReflow(paneId: paneId)
    }

    /// Syncs a mirror tab's surface (OSC) title to the remote tmux window
    /// name: held while the cached classification says "shell" (the re-pull
    /// decides — replay or drop), the send deduped against the window's
    /// current tmux name, ownership recorded only after an actual send (a
    /// title merely matching a name another client set never claims the
    /// window).
    func syncSurfaceTitle(windowId: Int, name: String) {
        guard let panelId = panelIdByWindow[windowId],
              let paneId = panelIdByPane.first(where: { $0.value == panelId })?.key
        else { return }
        if lastReflowByPane[paneId]?.noReflow == false {
            pendingSurfaceTitleByWindow[windowId] = name
            #if DEBUG
            cmuxDebugLog("remote.title.hold window=@\(windowId) pane=%\(paneId) name=\"\(name.prefix(32))\"")
            #endif
            requeryReflow(paneId: paneId)
            return
        }
        pendingSurfaceTitleByWindow[windowId] = nil
        guard connection.windowsByID[windowId]?.name != name else { return }
        #if DEBUG
        cmuxDebugLog("remote.title.sync window=@\(windowId) pane=%\(paneId) name=\"\(name.prefix(32))\"")
        #endif
        connection.send("rename-window -t @\(windowId) \(RemoteTmuxHost.shellSingleQuoted(name))")
        setOSCTitleOwner(windowId: windowId, to: (paneId, name))
    }

    /// Pins `windowId`'s name (explicit user rename): plain tmux semantics — the
    /// name stays until renamed again. Enforced by clearing the ownership
    /// entry and any held title: nothing is left for the restore path to act on.
    func noteWindowNamePinned(windowId: Int) {
        setOSCTitleOwner(windowId: windowId, to: nil)
        pendingSurfaceTitleByWindow[windowId] = nil
    }

    /// Sole consumer of classification events. Cache first (the sync gate and
    /// the rebuild sweep read it), then settle a held title against the fresh
    /// result (TUI → replay, confirmed shell → drop), then the restore
    /// attempt, then the surface reflow routing.
    private func handlePaneReflow(paneId: Int, noReflow: Bool, command: String) {
        lastReflowByPane[paneId] = (noReflow, command)
        if let windowId = windowIdContaining(pane: paneId),
           let pending = pendingSurfaceTitleByWindow[windowId] {
            pendingSurfaceTitleByWindow[windowId] = nil
            #if DEBUG
            cmuxDebugLog(
                "remote.title.\(noReflow ? "replay" : "dropHeld") window=@\(windowId) "
                    + "pane=%\(paneId) name=\"\(pending.prefix(32))\""
            )
            #endif
            if noReflow { syncSurfaceTitle(windowId: windowId, name: pending) }
        }
        restoreAutomaticRenameIfNeeded(paneId: paneId, noReflow: noReflow, command: command)
        routeNoReflow(paneId: paneId, noReflow: noReflow)
    }

    /// The titling pane returned to a plain shell → hand naming back to tmux
    /// (see the section comment). A name mismatch is tolerated once — usually
    /// our own rename's `%window-renamed` echo still in flight; the next
    /// classification result, or the echo's own rebuild sweep, settles it —
    /// while a second consecutive mismatch means another client renamed the
    /// window: ownership is dropped so their name survives and the exit probe
    /// stops re-querying this pane.
    private func restoreAutomaticRenameIfNeeded(paneId: Int, noReflow: Bool, command: String) {
        guard !noReflow, let windowId = windowIdContaining(pane: paneId),
              let owner = oscTitleOwnerByWindow[windowId], owner.paneId == paneId else { return }
        guard connection.windowsByID[windowId]?.name == owner.name else {
            if owner.sawNameMismatch {
                #if DEBUG
                cmuxDebugLog("remote.title.disown window=@\(windowId) pane=%\(paneId) (renamed elsewhere)")
                #endif
                setOSCTitleOwner(windowId: windowId, to: nil)
            } else {
                // Direct write, NOT setOSCTitleOwner — that would reset the
                // strike (the pane id is unchanged, so the projection holds).
                oscTitleOwnerByWindow[windowId] = (owner.paneId, owner.name, true)
            }
            return
        }
        setOSCTitleOwner(windowId: windowId, to: nil)
        sendAutomaticNamingRestore(windowId: windowId, command: command)
        #if DEBUG
        cmuxDebugLog("remote.title.restore window=@\(windowId) pane=%\(paneId) cmd=\"\(command)\"")
        #endif
    }

    /// Renames `windowId` to `command` — tmux recomputes automatic names
    /// LAZILY, so without the explicit rename an idle pane keeps the dead
    /// TUI's name and no `%window-renamed` ever refreshes the tab — then
    /// unsets the window-local `automatic-rename` override the rename
    /// re-created, so future command changes rename automatically again.
    /// The rename is skipped when `command` is empty (pane never classified)
    /// or already the window's name; the unset always fires.
    private func sendAutomaticNamingRestore(windowId: Int, command: String) {
        if !command.isEmpty, connection.windowsByID[windowId]?.name != command {
            connection.send("rename-window -t @\(windowId) \(RemoteTmuxHost.shellSingleQuoted(command))")
        }
        connection.send("set-option -w -u -t @\(windowId) automatic-rename")
    }

    /// Applies a pane's reflow classification to its mirror surface (suppress
    /// reflow on resize for alt-screen / inline-TUI panes; allow it for shells).
    /// Routes exactly like ``routeOutput(paneId:data:)`` — multi-pane windows own
    /// their pane surfaces, single-pane windows use the tab's panel surface.
    private func routeNoReflow(paneId: Int, noReflow: Bool) {
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            mirror.surface(forPane: paneId)?.setManualIONoReflow(noReflow)
            return
        }
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return }
        panel.surface.setManualIONoReflow(noReflow)
    }

    /// Routes a split of a mirror window-tab (by its panel id) to tmux
    /// `split-window`, splitting the focused pane (or the window's only pane).
    /// Used by the split BUTTON / `shouldSplitPane` path, which works at the
    /// bonsplit-pane (tab) level rather than per mirror surface. Returns `true`
    /// if handled (the caller vetoes the local split).
    func requestSplit(windowPanelId panelId: UUID, vertical: Bool) -> Bool {
        guard !connection.exited, let windowId = windowId(forPanel: panelId) else { return false }
        let targetPane = windowMirrorByWindowId[windowId]?.activePaneId
            ?? connection.windowsByID[windowId]?.paneIDsInOrder.first
        guard let targetPane else { return false }
        connection.send("split-window \(vertical ? "-v" : "-h") -t @\(windowId).%\(targetPane)")
        return true
    }

    /// Whether `surfaceId` is one of this session mirror's pane surfaces — a
    /// single-pane display tab or any multi-pane window-mirror pane. Used to route
    /// a pasted image to this mirror's tmux host for SSH upload.
    func ownsSurface(_ surfaceId: UUID) -> Bool {
        paneId(forSurfaceId: surfaceId) != nil
    }

    /// The tmux pane id whose surface is `surfaceId` (single-pane display tab or
    /// multi-pane window-mirror pane), or nil if this mirror doesn't render it.
    /// Used to target a tmux paste at the pane behind a cmux surface.
    func paneId(forSurfaceId surfaceId: UUID) -> Int? {
        if let match = windowMirror(forSurfaceId: surfaceId) { return match.tmuxPaneId }
        guard let workspace else { return nil }
        for (paneId, panelId) in panelIdByPane
        where (workspace.panels[panelId] as? TerminalPanel)?.surface.id == surfaceId {
            return paneId
        }
        return nil
    }

    /// The multi-pane renderer + tmux pane id for a focused mirror surface, used
    /// by the split shortcut to route ⌘D to `split-window`.
    func windowMirror(forSurfaceId surfaceId: UUID) -> (mirror: RemoteTmuxWindowMirror, tmuxPaneId: Int)? {
        for mirror in windowMirrorByWindowId.values {
            for paneId in mirror.paneIDsInOrder {
                if mirror.surface(forPane: paneId)?.id == surfaceId {
                    return (mirror, paneId)
                }
            }
        }
        return nil
    }

    /// Computes the target tab order for a remote-tmux-driven reorder, or `nil`
    /// when no reorder is needed or safe. Pure helper called by
    /// `Workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder:)`.
    ///
    /// - Parameters:
    ///   - current: the workspace's current mirror-tab order (panel ids).
    ///   - requested: the tmux window order mapped to panel ids.
    /// - Returns: the new order to apply, or `nil` when the tabs already match
    ///   `requested` or when `requested` (restricted to currently-present tabs) is
    ///   not a permutation of `current` (sets diverge — leave the tabs untouched).
    nonisolated static func mirrorTabReorder(current: [UUID], requested: [UUID]) -> [UUID]? {
        let present = Set(current)
        let desired = requested.filter { present.contains($0) }
        guard desired.count == current.count, Set(desired) == present else { return nil }
        return desired == current ? nil : desired
    }
}
