# Clicky - Agent Instructions

## Overview

macOS menu bar companion app repurposed as a **step-by-step UI navigation guide** for SaaS products. Lives entirely in the macOS status bar (no dock icon, no main window). The user presses **Cmd+K** anywhere on their system, types a question (e.g., "How do I create a read replica?"), and the blue cursor companion guides them step-by-step — flying to each UI element they need to click, waiting for them to click it, then re-analyzing the screen and pointing to the next step.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Input**: Text-only via Cmd+K global shortcut. No voice input, no TTS.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Click Detection**: Listen-only CGEvent tap detects mouse clicks to advance the navigation loop.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### Navigation Loop (Core Flow)

```
Cmd+K → Text prompt → Claude plans steps →
  ┌─────────────────────────────────────┐
  │  Point cursor to step N             │
  │  Show instruction bubble            │
  │  Listen for click event (CGEvent)   │
  │  Click detected → wait 1.5s         │
  │  Re-screenshot → send to Claude     │
  │  Claude confirms → advance to N+1   │
  └──────────────┬──────────────────────┘
                 │ loop until done
                 ▼
           "All done!"
```

### Navigation State Machine

```swift
enum NavigationState {
    case idle                    // No active navigation
    case awaitingInput           // Cmd+K prompt is open
    case planning                // Claude is analyzing screen
    case pointingAtStep(step, total)  // Cursor flying to / pointing at target
    case awaitingUserClick       // Waiting for user to click
    case verifyingStepCompletion // Re-screenshotting after click
    case completed               // All steps done
}
```

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |

Worker secrets: `ANTHROPIC_API_KEY`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, instruction bubbles, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Shortcut via CGEvent Tap**: Cmd+K and mouse click detection use a listen-only `CGEvent` tap on `.cgSessionEventTap`. This runs on the main thread via `CFRunLoopGetMain()` and never intercepts events (`.listenOnly` mode).

**Cmd+K Input Panel**: Uses the same `KeyablePanel` pattern as the menu bar panel — a borderless `NSPanel` with `.nonactivatingPanel` style that overrides `canBecomeKey` to allow text field focus. Excluded from screenshots via `sharingType = .none`.

**Multi-Step Navigation**: After each step, the cursor stays at the target (does NOT auto-fly back). `CompanionManager.onPointingAnimationCompleted()` transitions to `awaitingUserClick` and enables click monitoring. When a click is detected, there's a 1.5s delay (for page transitions) before re-screenshotting and asking Claude for the next step.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~85 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window. |
| `CompanionManager.swift` | ~430 | Central state machine. Owns the navigation loop: Cmd+K handling, Claude API calls, coordinate transforms, click detection, step advancement. Defines `NavigationState` enum. |
| `GlobalShortcutMonitor.swift` | ~130 | System-wide shortcut monitor. Listen-only CGEvent tap for Cmd+K, Escape, and mouse clicks. Publishes via Combine. |
| `CmdKInputPanelManager.swift` | ~210 | Floating text input panel. KeyablePanel + SwiftUI text field. Appears near cursor on Cmd+K, excluded from screenshots. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle for the menu bar dropdown. |
| `CompanionPanelView.swift` | ~420 | SwiftUI panel content. Shows navigation status, step progress, permissions UI, model picker, and quit button. |
| `OverlayWindow.swift` | ~530 | Full-screen transparent overlay hosting the blue cursor, instruction bubbles, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping. |
| `CompanionResponseOverlay.swift` | ~217 | Cursor-following response text overlay (legacy, currently unused). |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE). TLS warmup optimization, image MIME detection, conversation history support. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing (Computer Use API). |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~70 | Cloudflare Worker proxy. Single route: `/chat` (Claude). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

### Setup Steps

1. **Deploy the Cloudflare Worker** with your `ANTHROPIC_API_KEY` secret
2. **Update the worker URL** in `CompanionManager.swift` line 59 (`workerBaseURL`)
3. **Open in Xcode**, set your signing team, Cmd+R
4. **Grant permissions**: Accessibility, Screen Recording, Screen Content
5. **Click Start** in the menu bar panel
6. **Press Cmd+K** to start navigating

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
