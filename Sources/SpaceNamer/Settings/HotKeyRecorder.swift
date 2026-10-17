import AppKit
import Carbon.HIToolbox
import SpaceNamerCore
import SwiftUI

/// Click, then press a shortcut. Esc cancels, Delete clears.
final class HotKeyRecorderView: NSControl {
    var hotKey: HotKey? {
        didSet {
            guard hotKey != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(hotKey?.displayString ?? "None")
        }
    }
    var onChange: ((HotKey?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var isRecording = false
    private var liveModifiers: NSEvent.ModifierFlags = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    private var clearRect: NSRect {
        NSRect(x: bounds.maxX - 22, y: bounds.midY - 8, width: 16, height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hotKey != nil, !isRecording, clearRect.insetBy(dx: -3, dy: -3).contains(point) {
            commit(nil)
            return
        }
        if isRecording {
            stopRecording()
        } else {
            window?.makeFirstResponder(self)
            startRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if [kVK_Space, kVK_Return].contains(Int(event.keyCode)) { startRecording() } else { super.keyDown(with: event) }
            return
        }
        record(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return false }
        record(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isRecording { stopRecording() }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        liveModifiers = []
        onRecordingChange?(true)
        needsDisplay = true
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        liveModifiers = []
        onRecordingChange?(false)
        needsDisplay = true
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if modifiers.isEmpty {
            switch Int(event.keyCode) {
            case kVK_Escape:
                stopRecording()
                return
            case kVK_Delete, kVK_ForwardDelete:
                stopRecording()
                commit(nil)
                return
            default:
                break
            }
        }
        let candidate = HotKey(keyCode: event.keyCode, cocoaModifiers: modifiers.rawValue)
        guard candidate.isValidGlobalShortcut else {
            NSSound.beep()
            return
        }
        stopRecording()
        commit(candidate)
    }

    private func commit(_ newValue: HotKey?) {
        hotKey = newValue
        onChange?(newValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = liveModifiers.isEmpty ? "Type shortcut…" : HotKey.modifierSymbols(carbon: HotKey.carbonModifiers(fromCocoa: liveModifiers.rawValue))
            color = .secondaryLabelColor
        } else if let hotKey {
            text = hotKey.displayString
            color = .labelColor
        } else {
            text = "Record Shortcut"
            color = .tertiaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let trailingSpace: CGFloat = hotKey != nil && !isRecording ? 24 : 8
        let available = bounds.width - 8 - trailingSpace
        let x = 8 + max(0, (available - size.width) / 2)
        (text as NSString).draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attributes)

        if hotKey != nil, !isRecording,
           let clear = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear") {
            let tinted = NSImage(size: clearRect.size, flipped: false) { imageRect in
                clear.draw(in: imageRect)
                NSColor.tertiaryLabelColor.set()
                imageRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: clearRect)
        }
    }
}

/// SwiftUI wrapper that also pauses the app's own shortcuts while recording, so pressing
/// an existing shortcut records it instead of triggering it.
struct HotKeyField: NSViewRepresentable {
    @Binding var hotKey: HotKey?
    let model: AppModel

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onRecordingChange = { recording in model.suspendHotKeys(recording) }
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.hotKey = hotKey
        view.onChange = { hotKey = $0 }
    }
}

/// A recorder plus a warning line when the shortcut can't work.
struct ShortcutRecorder: View {
    @Binding var hotKey: HotKey?
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HotKeyField(hotKey: $hotKey, model: model)
                .frame(width: 150, height: 24)
            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var warning: String? {
        guard let hotKey else { return nil }
        if SymbolicHotKeys.conflicts(with: hotKey) { return "macOS already uses this shortcut" }
        if model.unavailableHotKeys.contains(hotKey) { return "In use by another app or shortcut" }
        return nil
    }
}
