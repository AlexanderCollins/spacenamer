#if DEBUG
import AppKit
import ApplicationServices
import CGSBridge
import SpaceNamerCore

/// Development-only hooks (`spacenamer://debug/...`), compiled out of release builds.
@MainActor
enum DebugCommands {
    static func handle(_ url: URL, model: AppModel) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value }
        let output = query["out"] ?? NSTemporaryDirectory() + "spacenamer-debug.txt"

        switch url.path {
        case "/swipe":
            let progress = Double(query["progress"] ?? "1") ?? 1
            let changed = Double(query["changed"] ?? "0.1") ?? 0.1
            let velocity = Double(query["velocity"] ?? "4000") ?? 4000
            let count = Int(query["count"] ?? "1") ?? 1
            let gap = UInt64(query["gap"] ?? "0") ?? 0
            let skipChanged = query["nochanged"] != nil
            Task {
                for index in 0..<count {
                    SNPostDockSwipe(.began, 0, 0)
                    if !skipChanged { SNPostDockSwipe(.changed, changed, 0) }
                    SNPostDockSwipe(.ended, progress, velocity)
                    if gap > 0, index < count - 1 { try? await Task.sleep(nanoseconds: gap * 1_000_000) }
                }
            }
        case "/vswipe":
            // Opens Mission Control in steps by holding a vertical swipe at each progress.
            let steps = (query["steps"] ?? "-0.2,-0.4,-0.6,-0.8,-1.0").split(separator: ",").compactMap { Double($0) }
            let hold = UInt64(query["hold"] ?? "350") ?? 350
            Task {
                SNPostDockSwipeWithMotion(.began, .vertical, 0, 0)
                for step in steps {
                    SNPostDockSwipeWithMotion(.changed, .vertical, step, 0)
                    try? await Task.sleep(nanoseconds: hold * 1_000_000)
                }
                SNPostDockSwipeWithMotion(.ended, .vertical, steps.last ?? -1, Double(query["velocity"] ?? "-2.5") ?? -2.5)
            }
        case "/cgs-observe":
            SNDebugObserveNotifications(Int32(query["from"] ?? "0") ?? 0, Int32(query["to"] ?? "2000") ?? 2000)
        case "/gesture":
            // Streams a vertical three-finger swipe like a trackpad does (one update per
            // ~8 ms). path: comma-separated progress waypoints, each reached over `step` ms.
            let path = (query["path"] ?? "0,-0.5,-0.5,-1.0").split(separator: ",").compactMap { Double($0) }
            let stepMs = Double(query["step"] ?? "300") ?? 300
            let velocity = Double(query["velocity"] ?? "-2.5") ?? -2.5
            let motion: SNSwipeMotion = query["motion"] == "h" ? .horizontal : .vertical
            let options = SNSwipeOptions(rawValue: UInt32(query["options"] ?? "0") ?? 0)
            Task {
                SNPostDockSwipeWithOptions(.began, motion, path.first ?? 0, 0, options)
                var current = path.first ?? 0
                let durations = (query["steps"] ?? "").split(separator: ",").compactMap { Double($0) }
                for (index, target) in path.dropFirst().enumerated() {
                    let segment = index < durations.count ? durations[index] : stepMs
                    let frames = max(1, Int(segment / 8))
                    let start = current
                    for frame in 1...frames {
                        try? await Task.sleep(nanoseconds: 8_000_000)
                        current = start + (target - start) * Double(frame) / Double(frames)
                        SNPostDockSwipeWithOptions(.changed, motion, current, 0, options)
                    }
                }
                try? await Task.sleep(nanoseconds: 8_000_000)
                SNPostDockSwipeWithOptions(query["end"] == "cancel" ? .cancelled : .ended, motion, current, velocity, options)
            }
        case "/reorder":
            // Closed-loop drag in Mission Control: picks up the thumbnail at `from` (1-based)
            // and releases it once the Dock's live order has it at `to`.
            guard let from = query["from"].flatMap(Int.init), let to = query["to"].flatMap(Int.init) else { return }
            reorder(from: from, to: to, output: output)
        case "/mc-add", "/mc-remove":
            // Presses Mission Control's "add desktop" button, or removes the desktop at `position`.
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            var found = firstSpaceButton(app)
            for _ in 0..<25 where found == nil {
                usleep(20_000) // the Dock briefly rebuilds Mission Control's tree after changes
                found = firstSpaceButton(app)
            }
            guard let first = found else { write("ABORT: Mission Control not open", to: output); return }
            var list: AnyObject?, bar: AnyObject?
            AXUIElementCopyAttributeValue(first, kAXParentAttribute as CFString, &list)
            AXUIElementCopyAttributeValue(list as! AXUIElement, kAXParentAttribute as CFString, &bar)
            var children: AnyObject?
            if url.path == "/mc-add" {
                AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
                let add = (children as? [AXUIElement] ?? []).first { element in
                    var id: AnyObject?
                    AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &id)
                    return (id as? String) == "mc.spaces.add"
                }
                let result = add.map { AXUIElementPerformAction($0, kAXPressAction as CFString).rawValue } ?? -1
                write(String(format: "%.4f add result %d", CACurrentMediaTime(), result), to: output)
            } else {
                AXUIElementCopyAttributeValue(list as! AXUIElement, kAXChildrenAttribute as CFString, &children)
                let buttons = children as? [AXUIElement] ?? []
                guard let position = query["position"].flatMap(Int.init), buttons.indices.contains(position - 1) else {
                    write("ABORT: no desktop at that position (\(buttons.count) desktops)", to: output); return
                }
                let result = AXUIElementPerformAction(buttons[position - 1], "AXRemoveDesktop" as CFString).rawValue
                write(String(format: "%.4f remove %d result %d", CACurrentMediaTime(), position, result), to: output)
            }
        case "/watch-bar":
            // Logs every change to the bar's frames (bar, list, first/last thumbnail, + button)
            // for `duration` seconds, polling every 4 ms.
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            let duration = Double(query["duration"] ?? "1.5") ?? 1.5
            Task.detached {
                var lines: [String] = []
                var last = ""
                let start = CACurrentMediaTime()
                func frame(_ element: AXUIElement?) -> String {
                    guard let element else { return "-" }
                    var value: AnyObject?
                    guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success, let value else { return "?" }
                    var rect = CGRect.zero
                    AXValueGetValue(value as! AXValue, .cgRect, &rect)
                    return "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
                }
                func children(_ element: AXUIElement?) -> [AXUIElement] {
                    guard let element else { return [] }
                    var value: AnyObject?
                    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                    return value as? [AXUIElement] ?? []
                }
                while CACurrentMediaTime() - start < duration {
                    let first = DebugCommands.firstSpaceButtonNonisolated(app)
                    var list: AnyObject?, bar: AnyObject?
                    if let first { AXUIElementCopyAttributeValue(first, kAXParentAttribute as CFString, &list) }
                    if let list { AXUIElementCopyAttributeValue(list as! AXUIElement, kAXParentAttribute as CFString, &bar) }
                    let buttons = children(list as! AXUIElement?)
                    let barChildren = children(bar as! AXUIElement?)
                    let line = "bar \(frame(bar as! AXUIElement?)) list \(frame(list as! AXUIElement?)) n=\(buttons.count) first \(frame(buttons.first)) last \(frame(buttons.last)) add \(frame(barChildren.last))"
                    if line != last {
                        lines.append(String(format: "%.4f ", CACurrentMediaTime()) + line)
                        last = line
                    }
                    usleep(4000)
                }
                try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
            }
        case "/mouse":
            // Scripted pointer actions inside Mission Control, e.g. drag a thumbnail:
            // actions=move:900:40,down,move:1100:110@20,up  (each step 16 ms apart; @n = n steps)
            let actions = (query["actions"] ?? "").split(separator: ",").map(String.init)
            Task {
                var point = DisplayResolver.cursorLocation() ?? .zero
                for action in actions {
                    let parts = action.split(separator: "@")
                    let steps = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                    let fields = parts[0].split(separator: ":")
                    switch fields.first {
                    case "move", "drag":
                        guard fields.count == 3, let x = Double(fields[1]), let y = Double(fields[2]) else { continue }
                        let start = point
                        for step in 1...steps {
                            point = CGPoint(x: start.x + (x - start.x) * Double(step) / Double(steps), y: start.y + (y - start.y) * Double(step) / Double(steps))
                            let type: CGEventType = fields.first == "drag" ? .leftMouseDragged : .mouseMoved
                            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                            try? await Task.sleep(nanoseconds: 16_000_000)
                        }
                    case "down":
                        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    case "up":
                        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    case "wait":
                        let ms = fields.count > 1 ? UInt64(fields[1]) ?? 100 : 100
                        try? await Task.sleep(nanoseconds: ms * 1_000_000)
                    default:
                        break
                    }
                }
            }
        case "/key":
            if let code = query["code"].flatMap(UInt16.init) {
                // e.g. code=125&control=1 for ⌃↓ (App Exposé)
                var flags: UInt64 = 0
                if query["control"] != nil { flags |= CGEventFlags.maskControl.rawValue }
                if query["option"] != nil { flags |= CGEventFlags.maskAlternate.rawValue }
                EventSynth.press(SystemShortcut(keyCode: code, modifierFlags: flags))
                return
            }
            let direction = Int(query["direction"] ?? "1") ?? 1
            if let shortcut = SymbolicHotKeys.moveSpace(direction: direction) { EventSynth.press(shortcut) }
        case "/dock-ax":
            write(dumpDock(maxDepth: Int(query["depth"] ?? "8") ?? 8), to: output)
        case "/mission-control":
            startObservingDock(log: output + ".notifications")
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            let delay = Double(query["delay"] ?? "1.2") ?? 1.2
            let original = DisplayResolver.cursorLocation()
            if let hoverY = query["hoverY"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    for step in 0..<6 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.05) {
                            let point = CGPoint(x: 900 + Double(step) * 4, y: hoverY)
                            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        }
                    }
                }
            }
            if let leaveAt = query["leaveAt"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + leaveAt) {
                    for step in 0..<6 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.03) {
                            let point = CGPoint(x: 900, y: 300 + Double(step) * 60)
                            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let original, query["hoverY"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { CGWarpMouseCursorPosition(original) }
                }
                write(dumpDock(maxDepth: Int(query["depth"] ?? "8") ?? 8), to: output)
                if query["stay"] == nil {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
                }
            }
        case "/mc-timing":
            // Poll the Dock's AX tree every 4 ms after opening Mission Control and log
            // when the Mission Control group first appears.
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            let started = Date()
            var lines: [String] = []
            var seen = false
            func stamp() -> String { String(format: "%.0fms", Date().timeIntervalSince(started) * 1000) }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            lines.append("start wall \(formatter.string(from: started))")
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            lines.append("\(stamp()) open requested")
            Task {
                for _ in 0..<200 {
                    var value: AnyObject?
                    AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value)
                    let children = value as? [AXUIElement] ?? []
                    let hasMC = children.contains { child in
                        var id: AnyObject?
                        AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &id)
                        return (id as? String) == "mc"
                    }
                    if hasMC != seen {
                        seen = hasMC
                        lines.append("\(stamp()) mc group \(hasMC ? "appeared" : "gone")")
                    }
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
                write(lines.joined(separator: "\n"), to: output)
            }
        case "/mc-sequence":
            // Drives Mission Control on a schedule and logs, on the host clock, when the
            // Dock's AX state changes. steps: action@seconds, comma separated.
            // Actions: key (Mission Control shortcut), hover, leave, esc.
            runSequence(query["steps"] ?? "key@0,hover@0.8,leave@1.6,key@2.4", duration: Double(query["duration"] ?? "3.2") ?? 3.2, output: output)
        case "/overlay-dump":
            var lines: [String] = []
            for window in NSApp.windows where window is OverlayWindow {
                let canvas = (window as! OverlayWindow).canvas
                lines.append("window \(window.frame) visible=\(window.isVisible) level=\(window.level.rawValue) root=\(canvas.root.frame) flipped=\(canvas.root.isGeometryFlipped) hostLayer=\(window.contentView?.layer === canvas.root) slide=\(canvas.slide.frame) slideOpacity=\(canvas.slide.opacity) offset=\(canvas.presentedOffset) sublayers=\(canvas.slide.sublayers?.count ?? 0)")
                for layer in canvas.slide.sublayers ?? [] {
                    lines.append("  label pos=\(layer.position) bounds=\(layer.bounds) opacity=\(layer.opacity) bg=\(String(describing: layer.backgroundColor)) hidden=\(layer.isHidden)")
                }
                let size = canvas.root.bounds.size
                if let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    canvas.root.render(in: context)
                    if let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output + ".png") as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil)
                        CGImageDestinationFinalize(destination)
                    }
                }
            }
            write(lines.joined(separator: "\n"), to: output)
        case "/state":
            let snapshot = model.snapshot
            var lines = ["canPost=\(EventSynth.canPost) displays=\(snapshot.displays.count)"]
            for space in snapshot.allSpaces {
                lines.append("\(space.position.map(String.init) ?? "-") \(space.kind) \(model.title(for: space)) key=\(space.key) current=\(snapshot.isCurrent(space))")
            }
            write(lines.joined(separator: "\n"), to: output)
        default:
            NSSound.beep()
        }
    }

    private static func runSequence(_ steps: String, duration: Double, output: String) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var lines: [String] = []
        func log(_ text: String) { lines.append(String(format: "%.4f ", CACurrentMediaTime()) + text) }
        let start = CACurrentMediaTime()
        func moveMouse(toY y: Double) {
            for step in 0..<6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.016) {
                    let point = CGPoint(x: 900 + Double(step) * 3, y: y + Double(step) * (y > 100 ? 40 : 0))
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            }
        }
        for step in steps.split(separator: ",") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { continue }
            let action = String(parts[0])
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                log("action \(action)")
                switch action {
                case "key": if let shortcut = SymbolicHotKeys.missionControl().last { EventSynth.press(shortcut) }
                case "hover": moveMouse(toY: 40)
                case "leave": moveMouse(toY: 420)
                case "esc": EventSynth.press(SystemShortcut(keyCode: 53, modifierFlags: 0))
                default: break
                }
            }
        }
        Task {
            var lastCount = -1
            var lastFrame = CGRect.null
            var button: AXUIElement?
            while CACurrentMediaTime() - start < duration {
                var count: CFIndex = 0
                AXUIElementGetAttributeValueCount(app, kAXChildrenAttribute as CFString, &count)
                if count != lastCount {
                    log("dock children \(count)")
                    lastCount = count
                    button = nil
                }
                if count > 1, button == nil {
                    button = firstSpaceButton(app)
                }
                if let button {
                    var value: AnyObject?
                    if AXUIElementCopyAttributeValue(button, "AXFrame" as CFString, &value) == .success, let value {
                        var rect = CGRect.zero
                        AXValueGetValue(value as! AXValue, .cgRect, &rect)
                        if rect != lastFrame {
                            var barRect = CGRect.zero
                            var parent: AnyObject?, grand: AnyObject?, barValue: AnyObject?
                            if AXUIElementCopyAttributeValue(button, kAXParentAttribute as CFString, &parent) == .success,
                               let parent, AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXParentAttribute as CFString, &grand) == .success,
                               let grand, AXUIElementCopyAttributeValue(grand as! AXUIElement, "AXFrame" as CFString, &barValue) == .success, let barValue {
                                AXValueGetValue(barValue as! AXValue, .cgRect, &barRect)
                            }
                            log("label0 frame \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) bar \(Int(barRect.minY)) h\(Int(barRect.height))")
                            lastFrame = rect
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            write(lines.joined(separator: "\n"), to: output)
        }
    }

    nonisolated static func firstSpaceButtonNonisolated(_ app: AXUIElement) -> AXUIElement? {
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        func identifier(_ element: AXUIElement) -> String? {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value)
            return value as? String
        }
        guard let mc = children(app).first(where: { identifier($0) == "mc" }),
              let display = children(mc).first(where: { identifier($0) == "mc.display" }),
              let bar = children(display).first(where: { identifier($0) == "mc.spaces" }),
              let list = children(bar).first(where: { identifier($0) == "mc.spaces.list" })
        else { return nil }
        return children(list).first
    }

    private static func firstSpaceButton(_ app: AXUIElement) -> AXUIElement? {
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        func identifier(_ element: AXUIElement) -> String? {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value)
            return value as? String
        }
        guard let mc = children(app).first(where: { identifier($0) == "mc" }),
              let display = children(mc).first(where: { identifier($0) == "mc.display" }),
              let bar = children(display).first(where: { identifier($0) == "mc.spaces" }),
              let list = children(bar).first(where: { identifier($0) == "mc.spaces.list" })
        else { return nil }
        return children(list).first
    }

    private static func reorder(from: Int, to: Int, output: String) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        func buttons() -> [AXUIElement] {
            guard let first = firstSpaceButton(app) else { return [] }
            var parent: AnyObject?
            AXUIElementCopyAttributeValue(first, kAXParentAttribute as CFString, &parent)
            guard let parent else { return [] }
            var value: AnyObject?
            AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXChildrenAttribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        func frame(_ element: AXUIElement) -> CGRect {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value)
            var rect = CGRect.zero
            if let value { AXValueGetValue(value as! AXValue, .cgRect, &rect) }
            return rect
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        Task {
            var log: [String] = []
            defer { write(log.joined(separator: "\n"), to: output) }
            var list = buttons()
            guard list.count >= max(from, to), from != to else { log.append("ABORT: no bar or bad positions (\(list.count) labels)"); return }
            if frame(list[0]).height < 40 {
                post(.mouseMoved, CGPoint(x: frame(list[from - 1]).midX, y: 40))
                try? await Task.sleep(nanoseconds: 700_000_000)
                list = buttons()
            }
            guard list.count >= max(from, to), frame(list[0]).height >= 40 else { log.append("ABORT: bar did not expand"); return }
            let dragged = list[from - 1]
            var point = CGPoint(x: frame(dragged).midX, y: frame(dragged).midY)
            post(.mouseMoved, point)
            try? await Task.sleep(nanoseconds: 120_000_000)
            post(.leftMouseDown, point)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let step: CGFloat = to > from ? 4 : -4
            for index in 0..<600 {
                point.x += step
                post(.leftMouseDragged, point)
                try? await Task.sleep(nanoseconds: 14_000_000)
                if let position = buttons().firstIndex(where: { CFEqual($0, dragged) }), position == to - 1 {
                    log.append("reached slot \(to) after \(index + 1) steps at x=\(Int(point.x))")
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    post(.leftMouseUp, point)
                    return
                }
            }
            post(.leftMouseUp, point)
            log.append("gave up; released at x=\(Int(point.x))")
        }
    }

    private static var observer: AXObserver?
    private static var notificationLog: String = ""
    private static var notificationLogPath = ""
    private static let start = Date()

    private static func startObservingDock(log path: String) {
        guard observer == nil,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        notificationLogPath = path
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            var role: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            let line = String(format: "%.0fms ", Date().timeIntervalSince(DebugCommands.start) * 1000) + "\(notification) role=\(role as? String ?? "?")\n"
            MainActor.assumeIsolated {
                DebugCommands.notificationLog += line
                try? DebugCommands.notificationLog.write(toFile: DebugCommands.notificationLogPath, atomically: true, encoding: .utf8)
            }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for name in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", "AXExposeExit",
                     kAXUIElementDestroyedNotification, kAXCreatedNotification, kAXFocusedUIElementChangedNotification,
                     kAXWindowCreatedNotification, kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification] {
            let status = AXObserverAddNotification(created, app, name as CFString, nil)
            notificationLog += "subscribe \(name): \(status.rawValue)\n"
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private static func write(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func dumpDock(maxDepth: Int) -> String {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return "no dock" }
        var lines: [String] = []
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func describe(_ element: AXUIElement, depth: Int) {
            let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
            let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            let label = attribute(element, kAXDescriptionAttribute) as? String ?? ""
            let identifier = attribute(element, "AXIdentifier") as? String ?? ""
            var frameText = ""
            if let value = attribute(element, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID() {
                var rect = CGRect.zero
                AXValueGetValue(value as! AXValue, .cgRect, &rect)
                frameText = "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
            }
            var names: CFArray?
            AXUIElementCopyAttributeNames(element, &names)
            let attributeNames = (names as? [String] ?? []).joined(separator: ",")
            var actionNames: CFArray?
            AXUIElementCopyActionNames(element, &actionNames)
            let actions = (actionNames as? [String] ?? []).joined(separator: ",")
            lines.append(String(repeating: "  ", count: depth) + "\(role) [\(subrole)] title=\"\(title)\" desc=\"\(label)\" id=\"\(identifier)\" frame=\(frameText) actions=\(actions) attrs=\(attributeNames)")
            guard depth < maxDepth, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { describe(child, depth: depth + 1) }
        }
        describe(AXUIElementCreateApplication(dock.processIdentifier), depth: 0)
        return lines.joined(separator: "\n")
    }
}
#endif
