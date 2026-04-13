//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the step-by-step UI navigation guide.
//  Owns the Cmd+K shortcut, click detection, screen capture, Claude API,
//  and overlay management. Coordinates the full navigation loop:
//  Cmd+K → query → Claude → point at step → wait for click → repeat.
//

import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

/// The current phase of a navigation session.
enum NavigationState: Equatable {
    /// No active navigation — cursor follows the mouse
    case idle
    /// Cmd+K prompt is open, waiting for user to type and submit
    case awaitingInput
    /// Claude is analyzing the screen and planning the next step
    case planning
    /// Cursor is flying to or pointing at the current step's target element
    case pointingAtStep(step: Int, totalSteps: Int?)
    /// Cursor arrived at target, waiting for the user to click
    case awaitingUserClick
    /// User clicked — re-screenshotting and asking Claude for the next step
    case verifyingStepCompletion
    /// All steps complete
    case completed
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var navigationState: NavigationState = .idle
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    let globalShortcutMonitor = GlobalShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let cmdKInputPanelManager = CmdKInputPanelManager()

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    /// Conversation history for the current multi-step navigation session.
    /// Each entry tracks the user message and Claude's response for that step.
    private var navigationConversationHistory: [(userMessage: String, assistantResponse: String)] = []

    /// The original user query for the current navigation session.
    private var currentNavigationQuery: String?

    /// Current step number in the navigation sequence.
    private var currentStepNumber: Int = 0

    /// The currently running AI response task, if any. Cancelled on new
    /// queries or when the user cancels navigation.
    private var currentResponseTask: Task<Void, Never>?

    private var cmdKCancellable: AnyCancellable?
    private var escapeCancellable: AnyCancellable?
    private var mouseClickCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?

    /// True when all required permissions are granted.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed initial setup (all permissions granted at least once).
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🎯 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindShortcuts()
        // Eagerly touch the Claude API so its TLS warmup handshake completes early
        _ = claudeAPI

        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Marks onboarding as completed, dismisses the panel, and shows the overlay.
    func completeOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true
        ClickyAnalytics.trackOnboardingStarted()
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalShortcutMonitor.stop()
        overlayWindowManager.hideOverlay()
        currentResponseTask?.cancel()
        currentResponseTask = nil
        cmdKCancellable?.cancel()
        escapeCancellable?.cancel()
        mouseClickCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    // MARK: - Permissions

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalShortcutMonitor.start()
        } else {
            globalShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission)")
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }

        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Permission Polling

    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    // MARK: - Shortcut Bindings

    private func bindShortcuts() {
        cmdKCancellable = globalShortcutMonitor.cmdKPressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleCmdKPressed()
            }

        escapeCancellable = globalShortcutMonitor.escapePressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapePressed()
            }

        mouseClickCancellable = globalShortcutMonitor.mouseClickedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clickLocation in
                self?.handleUserClickDuringNavigation(at: clickLocation)
            }
    }

    // MARK: - Cmd+K Handling

    private func handleCmdKPressed() {
        switch navigationState {
        case .idle:
            guard allPermissionsGranted else { return }

            // Show overlay if not already visible
            if !isOverlayVisible && isClickyCursorEnabled {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            navigationState = .awaitingInput
            cmdKInputPanelManager.showPanel(
                onSubmit: { [weak self] query in
                    self?.submitNavigationQuery(query)
                },
                onCancel: { [weak self] in
                    self?.navigationState = .idle
                }
            )

        case .awaitingInput:
            // Toggle off — dismiss input
            cancelNavigation()

        default:
            // Cancel active navigation
            cancelNavigation()
        }
    }

    private func handleEscapePressed() {
        switch navigationState {
        case .idle:
            break
        default:
            cancelNavigation()
        }
    }

    // MARK: - Navigation Loop

    /// Starts a new multi-step navigation session from the user's query.
    func submitNavigationQuery(_ query: String) {
        cmdKInputPanelManager.hidePanel()
        currentNavigationQuery = query
        navigationConversationHistory = []
        currentStepNumber = 0
        navigationState = .planning

        currentResponseTask?.cancel()
        currentResponseTask = Task {
            await executeNavigationStep(isInitialQuery: true, userQuery: query)
        }
    }

    /// Executes a single navigation step: screenshot → Claude → parse → point.
    /// Called for both the initial query and each subsequent click-triggered step.
    private func executeNavigationStep(isInitialQuery: Bool, userQuery: String? = nil) async {
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard !Task.isCancelled else { return }

            let labeledImages = screenCaptures.map { capture in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }

            let userPrompt: String
            if isInitialQuery {
                userPrompt = userQuery ?? ""
            } else {
                userPrompt = "the user has clicked. here is the current screen state. what should they click next? if the task is complete, respond with [POINT:none] and a completion message."
            }

            let historyForAPI = navigationConversationHistory.map { entry in
                (userPlaceholder: entry.userMessage, assistantResponse: entry.assistantResponse)
            }

            let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                images: labeledImages,
                systemPrompt: Self.navigationStepSystemPrompt,
                conversationHistory: historyForAPI,
                userPrompt: userPrompt,
                onTextChunk: { _ in }
            )

            guard !Task.isCancelled else { return }

            let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

            // Save to conversation history
            navigationConversationHistory.append((
                userMessage: userPrompt,
                assistantResponse: parseResult.spokenText
            ))

            // Keep history bounded
            if navigationConversationHistory.count > 20 {
                navigationConversationHistory.removeFirst(navigationConversationHistory.count - 20)
            }

            ClickyAnalytics.trackAIResponseReceived(response: parseResult.spokenText)

            if let pointCoordinate = parseResult.coordinate {
                currentStepNumber += 1

                // Pick the screen capture matching Claude's screen number
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                guard let targetScreenCapture else { return }

                let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                let displayFrame = targetScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Extract estimated total steps from response text (e.g. "Step 2 of ~5:")
                let estimatedTotalSteps = Self.extractStepTotal(from: parseResult.spokenText)

                navigationState = .pointingAtStep(step: currentStepNumber, totalSteps: estimatedTotalSteps)
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame

                ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                print("🎯 Step \(currentStepNumber): pointing at (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) — \"\(parseResult.elementLabel ?? "element")\"")
            } else {
                // No more steps — navigation complete
                navigationState = .completed
                detectedElementBubbleText = parseResult.spokenText
                print("🎯 Navigation complete: \(parseResult.spokenText)")

                // Auto-reset to idle after showing completion message
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    clearDetectedElementLocation()
                    navigationState = .idle
                }
            }
        } catch is CancellationError {
            // Navigation was cancelled
        } catch {
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            print("⚠️ Navigation step error: \(error)")
            navigationState = .idle
        }
    }

    /// Called by BlueCursorView after the cursor finishes its pointing
    /// animation (arrives at target and bubble text finishes streaming).
    /// Transitions to awaitingUserClick and enables click monitoring.
    func onPointingAnimationCompleted() {
        guard case .pointingAtStep = navigationState else { return }
        navigationState = .awaitingUserClick
        globalShortcutMonitor.isClickMonitoringEnabled = true
    }

    /// Handles a detected mouse click during the awaitingUserClick state.
    /// Re-screenshots after a delay and asks Claude for the next step.
    private func handleUserClickDuringNavigation(at clickLocation: CGPoint) {
        guard navigationState == .awaitingUserClick else { return }

        navigationState = .verifyingStepCompletion
        globalShortcutMonitor.isClickMonitoringEnabled = false
        clearDetectedElementLocation()

        currentResponseTask?.cancel()
        currentResponseTask = Task {
            // Brief delay to let the page transition/load after the click
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await executeNavigationStep(isInitialQuery: false)
        }
    }

    /// Cancels any active navigation and returns to idle.
    func cancelNavigation() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        globalShortcutMonitor.isClickMonitoringEnabled = false
        clearDetectedElementLocation()
        navigationConversationHistory = []
        currentNavigationQuery = nil
        currentStepNumber = 0
        navigationState = .idle
        cmdKInputPanelManager.hidePanel()
    }

    // MARK: - Navigation System Prompt

    private static let navigationStepSystemPrompt = """
    you are a step-by-step UI navigation guide. the user wants to accomplish a task in the application shown on their screen. you can see their screen via screenshots.

    your job:
    1. analyze the current screen state
    2. determine the SINGLE next action the user should take
    3. respond with a brief instruction and a [POINT] tag pointing at exactly where they should click

    rules:
    - respond with exactly ONE step at a time. never give multiple steps in one response.
    - start your response with "step N:" where N is the step number (e.g., "step 1:", "step 2:")
    - if you can estimate the total steps, include it (e.g., "step 2 of ~5:")
    - keep instructions to one or two sentences. be specific about what to click.
    - always include a [POINT:x,y:label] tag at the end pointing at the exact element to click
    - the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    - if the element is on a different screen, append :screenN (e.g., [POINT:400,300:button:screen2])
    - when the task is complete (the user has reached their goal), respond with a completion message and [POINT:none]
    - if the current screen doesn't match what you expected (user clicked wrong thing, page loaded differently), adapt and guide them from the current state
    - if you need the user to type something (not just click), say "type [text] in the [field name]" and point at the field
    - all lowercase, casual but clear. no emojis.

    examples:
    - "step 1 of ~4: click on the services tab in the left sidebar [POINT:85,340:services tab]"
    - "step 2 of ~4: click the blue create service button in the top right [POINT:1150,95:create service]"
    - "step 3 of ~4: select postgresql from the service type list [POINT:640,280:postgresql]"
    - "all done! your read replica is set up and should start syncing shortly. [POINT:none]"
    """

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        let spokenText: String
        let coordinate: CGPoint?
        let elementLabel: String?
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    /// Extracts the estimated total steps from Claude's response text.
    /// Looks for patterns like "step 2 of ~5:" or "step 3 of 4:".
    static func extractStepTotal(from responseText: String) -> Int? {
        let pattern = #"step \d+ of ~?(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let totalRange = Range(match.range(at: 1), in: responseText),
              let total = Int(responseText[totalRange]) else {
            return nil
        }
        return total
    }
}
