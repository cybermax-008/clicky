//
//  CmdKInputPanelManager.swift
//  leanring-buddy
//
//  Floating text input panel that appears near the cursor when the user
//  presses Cmd+K. Follows the KeyablePanel pattern from MenuBarPanelManager
//  so the text field can receive keyboard focus in a non-activating panel.
//

import AppKit
import SwiftUI

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing the text field to receive focus.
private class CmdKKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// SwiftUI view for the Cmd+K text input prompt.
struct CmdKInputView: View {
    @Binding var queryText: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            TextField("Ask anything...", text: $queryText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit {
                    let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedQuery.isEmpty else { return }
                    onSubmit()
                }

            if !queryText.isEmpty {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.background.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 16, x: 0, y: 8)
        )
        .frame(width: 400)
    }
}

/// Manages the floating Cmd+K input panel lifecycle: creation, positioning,
/// showing, hiding, and forwarding the submitted query.
@MainActor
final class CmdKInputPanelManager {
    private var panel: NSPanel?
    private var onSubmitCallback: ((String) -> Void)?
    private var onCancelCallback: (() -> Void)?
    private var queryText: String = ""

    private let panelWidth: CGFloat = 432
    private let panelHeight: CGFloat = 44

    /// Shows the Cmd+K input panel near the current cursor position.
    func showPanel(
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmitCallback = onSubmit
        self.onCancelCallback = onCancel
        self.queryText = ""

        if panel == nil {
            createPanel()
        }

        positionPanelNearCursor()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    /// Hides the input panel and clears callbacks.
    func hidePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        onSubmitCallback = nil
        onCancelCallback = nil
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let inputPanel = CmdKKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        inputPanel.isFloatingPanel = true
        inputPanel.level = .floating
        inputPanel.isOpaque = false
        inputPanel.backgroundColor = .clear
        inputPanel.hasShadow = false
        inputPanel.hidesOnDeactivate = false
        inputPanel.isExcludedFromWindowsMenu = true
        inputPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        inputPanel.isMovableByWindowBackground = false
        inputPanel.titleVisibility = .hidden
        inputPanel.titlebarAppearsTransparent = true

        // Exclude from screenshots so it doesn't appear in screen captures
        inputPanel.sharingType = .none

        panel = inputPanel
        updatePanelContent()
    }

    private func updatePanelContent() {
        guard let panel else { return }

        // Use a wrapper that captures bindings for the SwiftUI view
        let viewModel = CmdKInputViewModel(
            onSubmit: { [weak self] query in
                self?.hidePanel()
                self?.onSubmitCallback?(query)
            },
            onCancel: { [weak self] in
                self?.hidePanel()
                self?.onCancelCallback?()
            }
        )

        let inputView = CmdKInputViewWrapper(viewModel: viewModel)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: inputView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.contentView = hostingView
    }

    // MARK: - Positioning

    private func positionPanelNearCursor() {
        guard let panel else { return }

        let mouseLocation = NSEvent.mouseLocation

        // Position the panel centered horizontally near the cursor,
        // slightly above the cursor so it doesn't obscure the click target
        let panelOriginX = mouseLocation.x - (panelWidth / 2)
        let panelOriginY = mouseLocation.y + 30

        // Clamp to the screen containing the cursor
        if let currentScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            let screenFrame = currentScreen.visibleFrame
            let clampedX = max(screenFrame.minX, min(panelOriginX, screenFrame.maxX - panelWidth))
            let clampedY = max(screenFrame.minY, min(panelOriginY, screenFrame.maxY - panelHeight))

            panel.setFrame(
                NSRect(x: clampedX, y: clampedY, width: panelWidth, height: panelHeight),
                display: true
            )
        } else {
            panel.setFrame(
                NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
                display: true
            )
        }
    }
}

// MARK: - View Model for Cmd+K Input

/// Observable view model that bridges the panel manager's callbacks to SwiftUI.
@MainActor
private class CmdKInputViewModel: ObservableObject {
    @Published var queryText: String = ""
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    init(onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    func submit() {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        onSubmit(trimmedQuery)
    }
}

/// Wrapper view that owns the CmdKInputViewModel as a StateObject.
private struct CmdKInputViewWrapper: View {
    @StateObject var viewModel: CmdKInputViewModel

    var body: some View {
        CmdKInputView(
            queryText: $viewModel.queryText,
            onSubmit: { viewModel.submit() },
            onCancel: { viewModel.onCancel() }
        )
    }
}
