// VisionPerception.swift - Vision-based perception tools for Ghost OS v2
//
// Maps to MCP tools: ghost_parse_screen, ghost_ground
//
// These tools use the Python vision sidecar (localhost:9876) for ML inference.
// The sidecar handles ShowUI-2B (VLM grounding) and future YOLO detection.
//
// Architecture:
//   ghost_parse_screen → AX tree + CDP fallback → structured elements
//                        (future: sidecar /detect → YOLO bounding boxes)
//   ghost_ground       → screenshot → sidecar /ground → (x, y) coordinates
//
// ghost_parse_screen works WITHOUT the vision sidecar — it collects
// interactive elements from the AX tree (native apps) or Chrome DevTools
// Protocol (web apps). The sidecar is only needed for ghost_ground.
//
// When YOLO detection is implemented in the sidecar, ghost_parse_screen
// will call /detect as a first-pass visual sweep, then layer AX data on top.

import AppKit
import AXorcist
import Foundation

/// Vision-based perception: when the AX tree isn't enough.
public enum VisionPerception {

    // MARK: - ghost_parse_screen

    /// Detect all interactive UI elements on the screen.
    ///
    /// Collection strategy (layered, most-to-least reliable):
    ///   1. AX tree — works perfectly for native macOS apps.
    ///   2. Chrome DevTools Protocol — falls back to CDP when Chrome's AX tree
    ///      returns only empty AXGroup nodes (typical for Gmail, Slack web, etc.).
    ///   3. Future: vision sidecar /detect (YOLO) — not yet implemented.
    ///      When available, it will detect elements that neither AX nor CDP can see.
    ///
    /// The vision sidecar is NOT required to run this tool. Call ``VisionPerception/groundElement(description:appName:cropBox:)``
    /// for VLM-based grounding of individual elements that this tool cannot find.
    public static func parseScreen(
        appName: String?,
        fullResolution: Bool
    ) -> ToolResult {
        // Take screenshot for context (we always capture so callers can verify the result)
        guard let screenshot = captureForVision(appName: appName, fullResolution: fullResolution) else {
            return ToolResult(
                success: false,
                error: "Screenshot capture failed",
                suggestion: "Ensure Screen Recording permission is granted"
            )
        }

        // ── Strategy 1: AX tree ───────────────────────────────────────────────────
        // Collect interactive elements with screen-absolute bounding boxes.
        // This is fast (~10ms) and accurate for native macOS apps.
        var elements: [[String: Any]] = []
        var detectionMethod = "ax-tree"
        var appDisplayName: String = appName ?? "frontmost app"

        let targetApp: NSRunningApplication?
        if let appName {
            targetApp = Perception.findApp(named: appName)
            if targetApp == nil {
                Log.warn("parseScreen: app '\(appName)' not found — skipping AX collection")
            }
        } else {
            targetApp = NSWorkspace.shared.frontmostApplication
        }

        if let app = targetApp {
            appDisplayName = app.localizedName ?? appDisplayName
            collectAXElements(
                for: app,
                screenshot: screenshot,
                results: &elements
            )
        }

        // ── Strategy 2: CDP fallback for web apps ─────────────────────────────────
        // Chrome exposes web content as deeply nested AXGroup nodes, so AX yields
        // very few (or zero) useful elements for Gmail, Notion, Slack web, etc.
        // CDP queries the real DOM and returns aria-labels, roles, and bounding boxes.
        // CDP coordinates are viewport-relative; we convert them to screen-absolute
        // using the Chrome window origin + toolbar height.
        var cdpAvailable = false
        if elements.count < minAXElementsBeforeCDPFallback, CDPBridge.isAvailable() {
            cdpAvailable = true

            // Get Chrome window origin for viewport → screen conversion
            let windowOrigin: (x: Double, y: Double)
            if let app = targetApp,
               let appElement = Element.application(for: app.processIdentifier),
               let window = appElement.focusedWindow(),
               let pos = window.position()
            {
                windowOrigin = (Double(pos.x), Double(pos.y))
            } else {
                windowOrigin = (0, 0)
            }

            if let cdpElements = CDPBridge.findElements(query: "") {
                // CDPBridge.findElements("") passes an empty query string.
                // In the CDP JavaScript, every string includes the empty string,
                // so this matches all elements with aria-label, placeholder,
                // button/link text, labels, title, or alt attributes.
                // CDPBridge caps results at 20 elements per call.
                let cdpSummaries: [[String: Any]] = cdpElements.compactMap { el in
                    guard let vx = el["centerX"] as? Int,
                          let vy = el["centerY"] as? Int
                    else { return nil }

                    // Convert viewport coords to screen-absolute coords
                    let screen = CDPBridge.viewportToScreen(
                        viewportX: Double(vx),
                        viewportY: Double(vy),
                        windowX: windowOrigin.x,
                        windowY: windowOrigin.y
                    )

                    var summary: [String: Any] = [
                        "role": el["role"] as? String ?? el["tag"] as? String ?? "unknown",
                        "name": (el["ariaLabel"] as? String)?.isEmpty == false
                                    ? el["ariaLabel"]!
                                    : el["text"] as? String ?? "",
                        "position": ["x": Int(screen.x), "y": Int(screen.y)],
                        "size": [
                            "width": el["width"] as? Int ?? 0,
                            "height": el["height"] as? Int ?? 0,
                        ],
                        "actionable": el["actionable"] as? Bool ?? true,
                        "source": "cdp",
                    ]
                    if let id = el["id"] as? String, !id.isEmpty {
                        summary["dom_id"] = id
                    }
                    return summary
                }
                if !cdpSummaries.isEmpty {
                    elements = cdpSummaries
                    detectionMethod = "cdp"
                }
            }
        }

        // ── Note YOLO status ──────────────────────────────────────────────────────
        // When the sidecar implements /detect, it will run here as a third strategy
        // that can find elements invisible to both AX and CDP (e.g. canvas UIs).
        let yoloAvailable = false  // Will become true when sidecar /detect is shipped
        let vlmAvailable = VisionBridge.isAvailable()

        // ── Build response ────────────────────────────────────────────────────────
        var data: [String: Any] = [
            "elements": elements,
            "element_count": elements.count,
            "app": appDisplayName,
            "screenshot_width": screenshot.width,
            "screenshot_height": screenshot.height,
            "detection_method": detectionMethod,
            "cdp_available": cdpAvailable,
            "vlm_available": vlmAvailable,
            "yolo_available": yoloAvailable,
        ]

        if !yoloAvailable {
            data["yolo_note"] = "YOLO element detection is not yet implemented. " +
                                "When available, it will detect canvas/WebGL elements " +
                                "that AX and CDP cannot see."
        }

        let suggestion: String
        if elements.isEmpty {
            suggestion = "No interactive elements found. " +
                         "For web apps with complex DOM, try ghost_ground with a visual description. " +
                         "For native apps, ensure Accessibility permission is granted."
        } else {
            suggestion = "Use ghost_click with the element name or x/y coordinates. " +
                         "For elements not listed (e.g. canvas or custom widgets), " +
                         "use ghost_ground with a visual description to locate them."
        }

        return ToolResult(
            success: true,
            data: data,
            suggestion: suggestion
        )
    }

    // MARK: - AX Element Collection (for ghost_parse_screen)

    /// Interactive AX roles we collect in parseScreen.
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXComboBox", "AXMenuButton", "AXTab", "AXSlider",
        "AXMenuItem", "AXSearchField",
    ]

    /// Minimum number of AX elements required before skipping the CDP fallback.
    /// Chrome's AX tree often returns very few meaningful elements for web apps
    /// (everything is AXGroup), so below this threshold we also query the DOM via CDP.
    private static let minAXElementsBeforeCDPFallback = 3

    /// Maximum number of elements returned to the caller.
    /// Keeps the MCP response payload manageable for the LLM context window.
    private static let maxElementsReturned = 60

    /// Internal over-collection cap. Deduplication can remove 30–50% of raw
    /// elements, so we collect headroom before trimming to maxElementsReturned.
    private static let maxCollectedElements = 200

    /// Tolerance (in logical points) for position-based element deduplication.
    /// Two elements within this distance with the same role are treated as one.
    private static let deduplicationTolerancePixels = 5.0

    /// Minimum element size (in logical points) for both dimensions.
    /// Elements smaller than this are invisible in practice and cannot be
    /// clicked reliably, so they are excluded from the results.
    private static let minElementSizePixels = 8.0

    /// Collect interactive elements from the AX tree with screen-absolute coordinates.
    /// Uses the same semantic-depth tunneling as ghost_annotate so layout containers
    /// (AXGroup, AXDiv) don't consume depth budget.
    private static func collectAXElements(
        for app: NSRunningApplication,
        screenshot: ScreenshotResult,
        results: inout [[String: Any]]
    ) {
        guard let appElement = Element.application(for: app.processIdentifier),
              let window = appElement.focusedWindow() ?? appElement.mainWindow()
        else { return }

        appElement.setMessagingTimeout(3.0)
        defer { appElement.setMessagingTimeout(0) }

        var collected: [ParsedElement] = []
        collectAXElementsRecursive(
            from: window,
            results: &collected,
            windowX: screenshot.windowX,
            windowY: screenshot.windowY,
            windowWidth: screenshot.windowWidth,
            windowHeight: screenshot.windowHeight,
            semanticDepth: 0,
            maxSemanticDepth: 15
        )

        // Deduplicate by position (within deduplicationTolerancePixels pt) and role
        var deduped: [ParsedElement] = []
        for elem in collected {
            let dominated = deduped.contains { ex in
                abs(ex.x - elem.x) < deduplicationTolerancePixels &&
                abs(ex.y - elem.y) < deduplicationTolerancePixels &&
                ex.role == elem.role
            }
            if !dominated { deduped.append(elem) }
        }

        // Sort: top-to-bottom, left-to-right
        deduped.sort { a, b in
            if abs(a.y - b.y) > 10 { return a.y < b.y }
            return a.x < b.x
        }

        // AX position() returns the top-left corner of the element.
        // We expose the center point so callers can pass it directly to ghost_click.
        results = deduped.prefix(maxElementsReturned).map { elem in
            var summary: [String: Any] = [
                "role": elem.role,
                "name": elem.name,
                "position": ["x": Int(elem.x + elem.width / 2), "y": Int(elem.y + elem.height / 2)],
                "size": ["width": Int(elem.width), "height": Int(elem.height)],
                "actionable": true,
                "source": "ax-tree",
            ]
            if !elem.domId.isEmpty { summary["dom_id"] = elem.domId }
            return summary
        }
    }

    /// Layout roles that cost zero semantic depth in the tunneling algorithm.
    private static let layoutRoles: Set<String> = [
        "AXGroup", "AXGenericElement", "AXSection", "AXDiv",
        "AXList", "AXLandmarkMain", "AXLandmarkNavigation",
        "AXLandmarkBanner", "AXLandmarkContentInfo",
    ]

    private struct ParsedElement {
        let role: String
        let name: String
        let domId: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private static func collectAXElementsRecursive(
        from element: Element,
        results: inout [ParsedElement],
        windowX: Double,
        windowY: Double,
        windowWidth: Double,
        windowHeight: Double,
        semanticDepth: Int,
        maxSemanticDepth: Int
    ) {
        guard semanticDepth <= maxSemanticDepth, results.count < maxCollectedElements else { return }

        let role = element.role() ?? ""

        // Semantic depth tunneling: empty layout containers cost 0
        let hasContent: Bool
        if layoutRoles.contains(role) {
            let title = element.title()
            let desc = element.descriptionText()
            hasContent = title != nil || desc != nil
        } else {
            hasContent = true
        }
        let childDepth = hasContent ? semanticDepth + 1 : semanticDepth

        if interactiveRoles.contains(role) {
            if let pos = element.position(), let size = element.size() {
                let x = Double(pos.x)
                let y = Double(pos.y)
                let w = Double(size.width)
                let h = Double(size.height)

                // Allow a small tolerance beyond the window frame: some elements
                // have hit-test areas that slightly overflow their parent window.
                let inBounds = x + w > windowX - deduplicationTolerancePixels &&
                               x < windowX + windowWidth + deduplicationTolerancePixels &&
                               y + h > windowY - deduplicationTolerancePixels &&
                               y < windowY + windowHeight + deduplicationTolerancePixels

                if inBounds && w >= minElementSizePixels && h >= minElementSizePixels {
                    let name = element.computedName() ?? element.title() ?? ""
                    let domId = element.rawAttributeValue(named: "AXDOMIdentifier") as? String ?? ""
                    results.append(ParsedElement(
                        role: role, name: name, domId: domId,
                        x: x, y: y, width: w, height: h
                    ))
                }
            }
        }

        guard let children = element.children() else { return }
        for child in children {
            collectAXElementsRecursive(
                from: child, results: &results,
                windowX: windowX, windowY: windowY,
                windowWidth: windowWidth, windowHeight: windowHeight,
                semanticDepth: childDepth, maxSemanticDepth: maxSemanticDepth
            )
        }
    }

    // MARK: - ghost_ground

    /// Find precise screen coordinates for a described UI element using VLM.
    /// Takes a screenshot, sends it to the vision sidecar with the description,
    /// and returns the (x, y) coordinates where the element was found.
    public static func groundElement(
        description: String,
        appName: String?,
        cropBox: [Double]?
    ) -> ToolResult {
        // Check sidecar availability, try to start it if not running
        if !VisionBridge.isAvailable() {
            Log.info("Vision sidecar not running, attempting to start...")
            if !VisionBridge.startSidecar() {
                return sidecarUnavailableResult(tool: "ghost_ground")
            }
        }

        // Take screenshot (1280px width is ideal for VLM)
        guard let screenshot = captureForVision(appName: appName, fullResolution: false) else {
            return ToolResult(
                success: false,
                error: "Screenshot capture failed",
                suggestion: "Ensure Screen Recording permission is granted"
            )
        }

        // ── Coordinate mapping strategy ──
        //
        // Problem: SCK's desktopIndependentWindow captures the FULL Chrome window
        // (tabs, address bar, web content) but reports the frame of only the
        // content sub-window. The relationship between SCK frame and actual
        // captured area is unreliable for Chrome/Electron apps.
        //
        // Solution: Pass the MAIN DISPLAY logical dimensions as screen_w/screen_h.
        // For a maximized/fullscreen app, the screenshot covers essentially the
        // full display. The VLM normalizes coordinates to [0,1] relative to the
        // image, and multiplying by display dimensions gives screen-absolute
        // coordinates directly — no offset needed.
        //
        // This works because:
        // 1. Chrome in fullscreen covers the entire display
        // 2. VLM sees the screenshot as covering the full display area
        // 3. Normalized coords * display size = screen absolute coords
        //
        // For non-fullscreen windows, we fall back to window-relative mapping.

        let screenshotWidth = Double(screenshot.width)
        let screenshotHeight = Double(screenshot.height)
        let windowWidth = screenshot.windowWidth
        let windowHeight = screenshot.windowHeight
        let windowX = screenshot.windowX
        let windowY = screenshot.windowY

        // Get main display dimensions for fullscreen mapping
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let displayWidth = Double(mainScreen?.frame.width ?? 1728)
        let displayHeight = Double(mainScreen?.frame.height ?? 1117)

        // Determine if window is effectively fullscreen (covers most of display width)
        let isEffectivelyFullscreen = windowWidth > 0 && (windowWidth / displayWidth) > 0.9

        let sidecarWidth: Double
        let sidecarHeight: Double
        let offsetX: Double
        let offsetY: Double

        if isEffectivelyFullscreen {
            // Fullscreen: use display dimensions, no offset
            sidecarWidth = displayWidth
            sidecarHeight = displayHeight
            offsetX = 0
            offsetY = 0
        } else if windowWidth > 0 && windowHeight > 0 {
            // Non-fullscreen: use window dimensions + offset
            sidecarWidth = windowWidth
            sidecarHeight = windowHeight
            offsetX = windowX
            offsetY = windowY
        } else {
            // Fallback: use screenshot pixels
            sidecarWidth = screenshotWidth
            sidecarHeight = screenshotHeight
            offsetX = 0
            offsetY = 0
        }

        // Call VLM grounding
        guard let result = VisionBridge.ground(
            imageBase64: screenshot.base64PNG,
            description: description,
            screenWidth: sidecarWidth,
            screenHeight: sidecarHeight,
            cropBox: cropBox
        ) else {
            return ToolResult(
                success: false,
                error: "VLM grounding failed for '\(description)'",
                suggestion: "The vision sidecar may have crashed. Check its logs or restart it."
            )
        }

        // Map to screen-absolute coordinates
        let mappedX = result.x + offsetX
        let mappedY = result.y + offsetY
        Log.info("Vision ground: sidecar(\(Int(sidecarWidth))x\(Int(sidecarHeight))) → VLM (\(Int(result.x)),\(Int(result.y))) + offset (\(Int(offsetX)),\(Int(offsetY))) → screen (\(Int(mappedX)),\(Int(mappedY))) [fullscreen=\(isEffectivelyFullscreen)]")

        // Build response with screen-logical coordinates
        var data: [String: Any] = [
            "x": mappedX,
            "y": mappedY,
            "confidence": result.confidence,
            "method": result.method,
            "description": description,
            "inference_ms": result.inferenceMs,
            "screen_size": ["width": Int(screenshotWidth), "height": Int(screenshotHeight)],
            "window_frame": [
                "x": Int(windowX), "y": Int(windowY),
                "width": Int(windowWidth), "height": Int(windowHeight),
            ],
            "display_size": ["width": Int(displayWidth), "height": Int(displayHeight)],
            "vlm_raw": ["x": result.x, "y": result.y],
        ]

        if let cropBox, cropBox.count == 4 {
            data["crop_box"] = cropBox
        }

        // Include suggestion based on confidence
        var suggestion: String?
        if result.confidence < 0.3 {
            suggestion = "Low confidence (\(result.confidence)). The element may not be visible on screen. " +
                         "Try ghost_screenshot to verify, or use ghost_find for AX-based search."
        } else if result.confidence < 0.6 {
            suggestion = "Medium confidence. Consider using crop_box to narrow the search area for better accuracy."
        }

        return ToolResult(
            success: result.confidence > 0,
            data: data,
            suggestion: suggestion
        )
    }

    // MARK: - Vision-Enhanced Find (fallback for ghost_find)

    /// Try to find an element using VLM grounding as a fallback when AX search fails.
    /// Called by Perception.findElements when AX returns no results.
    ///
    /// Returns a synthetic element summary with VLM-grounded coordinates that can
    /// be used directly with ghost_click(x:, y:).
    public static func visionFallbackFind(
        query: String,
        appName: String?
    ) -> [[String: Any]]? {
        // Only try if sidecar is available (don't block on startup)
        guard VisionBridge.isAvailable() else {
            return nil
        }

        // Take screenshot
        guard let screenshot = captureForVision(appName: appName, fullResolution: false) else {
            return nil
        }

        // Use display dimensions for fullscreen apps, window dims otherwise
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let displayW = Double(mainScreen?.frame.width ?? 1728)
        let displayH = Double(mainScreen?.frame.height ?? 1117)
        let isFullscreen = screenshot.windowWidth > 0 && (screenshot.windowWidth / displayW) > 0.9

        let sidecarW: Double
        let sidecarH: Double
        let offX: Double
        let offY: Double
        if isFullscreen {
            sidecarW = displayW; sidecarH = displayH; offX = 0; offY = 0
        } else if screenshot.windowWidth > 0 {
            sidecarW = screenshot.windowWidth; sidecarH = screenshot.windowHeight
            offX = screenshot.windowX; offY = screenshot.windowY
        } else {
            sidecarW = Double(screenshot.width); sidecarH = Double(screenshot.height)
            offX = 0; offY = 0
        }

        // Run VLM grounding
        guard let result = VisionBridge.ground(
            imageBase64: screenshot.base64PNG,
            description: query,
            screenWidth: sidecarW,
            screenHeight: sidecarH
        ) else {
            return nil
        }

        // Only return if confidence is reasonable
        guard result.confidence >= 0.5 else {
            Log.info("Vision fallback for '\(query)': low confidence \(result.confidence), skipping")
            return nil
        }

        let mappedX = Int(result.x + offX)
        let mappedY = Int(result.y + offY)

        Log.info("Vision fallback found '\(query)' at screen (\(mappedX), \(mappedY)) conf=\(result.confidence)")

        // Return as a synthetic element summary matching ghost_find's output format
        let element: [String: Any] = [
            "name": query,
            "role": "VisionGrounded",
            "position": ["x": mappedX, "y": mappedY],
            "size": ["width": 40, "height": 40],  // Approximate click target
            "actionable": true,
            "grounded_by": "vlm",
            "confidence": result.confidence,
            "note": "Found by VLM vision grounding. Use ghost_click with x:\(mappedX) y:\(mappedY) to click.",
        ]

        return [element]
    }

    // MARK: - Vision-Enhanced Click (fallback for ghost_click)

    /// Try to click an element using VLM grounding as a fallback when AX can't find it.
    /// Called by Actions.click when AX-based click fails.
    ///
    /// Takes a screenshot, runs VLM grounding to find the element, then clicks
    /// at the grounded coordinates.
    public static func visionFallbackClick(
        query: String,
        appName: String?
    ) -> ToolResult? {
        // Only try if sidecar is available
        guard VisionBridge.isAvailable() else {
            return nil
        }

        // Take screenshot
        guard let screenshot = captureForVision(appName: appName, fullResolution: false) else {
            return nil
        }

        // Use display dimensions for fullscreen apps, window dims otherwise
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let displayW = Double(mainScreen?.frame.width ?? 1728)
        let displayH = Double(mainScreen?.frame.height ?? 1117)
        let isFullscreen = screenshot.windowWidth > 0 && (screenshot.windowWidth / displayW) > 0.9

        let sidecarW: Double
        let sidecarH: Double
        let offX: Double
        let offY: Double
        if isFullscreen {
            sidecarW = displayW; sidecarH = displayH; offX = 0; offY = 0
        } else if screenshot.windowWidth > 0 {
            sidecarW = screenshot.windowWidth; sidecarH = screenshot.windowHeight
            offX = screenshot.windowX; offY = screenshot.windowY
        } else {
            sidecarW = Double(screenshot.width); sidecarH = Double(screenshot.height)
            offX = 0; offY = 0
        }

        // Run VLM grounding
        guard let result = VisionBridge.ground(
            imageBase64: screenshot.base64PNG,
            description: query,
            screenWidth: sidecarW,
            screenHeight: sidecarH
        ) else {
            return nil
        }

        // Only click if confidence is reasonable
        guard result.confidence >= 0.5 else {
            Log.info("Vision click fallback for '\(query)': low confidence \(result.confidence)")
            return nil
        }

        let mappedX = result.x + offX
        let mappedY = result.y + offY

        Log.info("Vision click: '\(query)' at screen (\(Int(mappedX)), \(Int(mappedY))) conf=\(result.confidence)")

        return ToolResult(
            success: true,
            data: [
                "x": mappedX,
                "y": mappedY,
                "confidence": result.confidence,
                "method": "vlm-grounded",
                "description": query,
                "inference_ms": result.inferenceMs,
                "note": "Element found by VLM vision grounding. Use ghost_click(x:\(Int(mappedX)), y:\(Int(mappedY))) to click.",
            ],
            suggestion: "To click this element, use ghost_click with x:\(Int(mappedX)) y:\(Int(mappedY))"
        )
    }

    // MARK: - Private Helpers

    /// Capture a screenshot suitable for vision processing.
    /// Uses the existing ScreenCapture module (same as ghost_screenshot).
    /// Includes activate-and-retry logic for windows that are off-screen.
    private static func captureForVision(
        appName: String?,
        fullResolution: Bool
    ) -> ScreenshotResult? {
        let targetApp: NSRunningApplication
        if let appName {
            guard let app = Perception.findApp(named: appName) else {
                return nil
            }
            targetApp = app
        } else {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            targetApp = frontApp
        }

        let pid = targetApp.processIdentifier

        // First attempt: capture without focus change.
        let (firstResult, firstFailure) = ScreenCapture.captureWindowSyncWithReason(
            pid: pid, fullResolution: fullResolution
        )
        if let firstResult {
            return firstResult
        }

        // If the failure is fixable by activating the app, try that.
        switch firstFailure {
        case .noPermission, .windowListUnavailable:
            // Cannot fix by activating.
            return nil
        case .noWindowsForApp, .captureReturnedNil, .imageTooSmall, nil:
            break
        }

        // Retry: activate the app to bring windows on-screen.
        Log.info("VisionCapture: retrying after focus for \(targetApp.localizedName ?? "app")")
        targetApp.activate()
        Thread.sleep(forTimeInterval: 0.5)

        let (retryResult, _) = ScreenCapture.captureWindowSyncWithReason(
            pid: pid, fullResolution: fullResolution
        )
        return retryResult
    }

    /// Standard error result when the vision sidecar is not available.
    private static func sidecarUnavailableResult(tool: String) -> ToolResult {
        ToolResult(
            success: false,
            error: "Vision sidecar not running. \(tool) requires the Python vision sidecar.",
            suggestion: "Start the sidecar: cd ghost-os-v2/vision-sidecar && python3 server.py &\n" +
                        "Or use ghost_find for AX-based element search (works without sidecar)."
        )
    }
}
