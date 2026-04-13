//
//  GlobalShortcutMonitor.swift
//  leanring-buddy
//
//  Captures global keyboard shortcuts (Cmd+K, Escape) and mouse clicks
//  while the app is running in the background. Uses a listen-only CGEvent
//  tap so shortcuts work system-wide without intercepting user input.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalShortcutMonitor: ObservableObject {
    /// Fires when the user presses Cmd+K anywhere in the system.
    let cmdKPressedPublisher = PassthroughSubject<Void, Never>()

    /// Fires when the user presses Escape anywhere in the system.
    let escapePressedPublisher = PassthroughSubject<Void, Never>()

    /// Fires when the user clicks the left mouse button. Only publishes
    /// when `isClickMonitoringEnabled` is true (during awaitingUserClick).
    /// The CGPoint is in CoreGraphics coordinates (top-left origin).
    let mouseClickedPublisher = PassthroughSubject<CGPoint, Never>()

    /// Set to true during awaitingUserClick state to start publishing
    /// mouse click events. Set to false at all other times.
    var isClickMonitoringEnabled = false

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// Key code constants
    private static let keyCodeK: UInt16 = 40
    private static let keyCodeEscape: UInt16 = 53

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.keyDown, .leftMouseUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<GlobalShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return monitor.handleGlobalEventTap(eventType: eventType, event: event)
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ GlobalShortcutMonitor: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ GlobalShortcutMonitor: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if macOS disabled it due to timeout
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if eventType == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            // Cmd+K: trigger the navigation prompt
            if keyCode == Self.keyCodeK && flags.contains(.maskCommand) {
                cmdKPressedPublisher.send()
            }

            // Escape: cancel navigation
            if keyCode == Self.keyCodeEscape {
                escapePressedPublisher.send()
            }
        }

        if eventType == .leftMouseUp && isClickMonitoringEnabled {
            let clickLocation = event.location
            mouseClickedPublisher.send(clickLocation)
        }

        return Unmanaged.passUnretained(event)
    }
}
