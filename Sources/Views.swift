// Menu bar icon drawing and the custom views of the menu (header, switch, status rows).

import AppKit

/// A menu bar icon (1x and @2x) read from another app's bundle, without modifying it.
func bundleIcon(_ resources: String, _ name: String, size: CGFloat) -> NSImage? {
    guard let image = NSImage(contentsOfFile: resources + name + ".png") else { return nil }
    image.size = NSSize(width: size, height: size)
    if let retina = NSImageRep(contentsOfFile: resources + name + "@2x.png") {
        retina.size = image.size
        image.addRepresentation(retina)
    }
    return image
}

let thatPetIcon = bundleIcon("/Applications/ThatPet.app/Contents/Resources/", "MenuBarIcon", size: 18)
let ollamaIcon = bundleIcon("/Applications/Ollama.app/Contents/Resources/", "ollama", size: 16)

func symbol(_ name: String, size: CGFloat = 8, weight: NSFont.Weight = .black) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
}

/// The two icon designs; the choice is saved in the app's preferences.
enum IconStyle: String, CaseIterable {
    case petAndOllama = "pet-ollama"  // ThatPet's cat and Ollama's llama peeking over the same edge, then "+"
    case petPlus = "pet-plus"         // ThatPet's cat with a "+" beside it

    var title: String { self == .petAndOllama ? "ThatPet | Ollama" : "ThatPet +" }

    static var current: IconStyle {
        get { IconStyle(rawValue: UserDefaults.standard.string(forKey: "IconStyle") ?? "") ?? .petAndOllama }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "IconStyle") }
    }
}

/// ThatPet's cat, identical and at the same height as its own, optionally with Ollama's
/// llama peeking over the same edge, and a "+" at the end.
func extensionIcon(_ style: IconStyle = .current) -> NSImage {
    let withLlama = style == .petAndOllama && ollamaIcon != nil
    let image = NSImage(size: NSSize(width: withLlama ? 37 : 24, height: 18), flipped: false) { _ in
        if let cat = thatPetIcon {
            cat.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        } else {
            symbol("cat.fill")?.draw(in: NSRect(x: 2, y: 3, width: 13, height: 13))
        }
        if withLlama, let llama = ollamaIcon {
            // only the part above the edge, so the llama peeks out like the cat
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 17, y: 6, width: 13, height: 12)).addClip()
            llama.draw(in: NSRect(x: 17, y: 2.5, width: 13, height: 13))
            NSGraphicsContext.restoreGraphicsState()
            // ThatPet's edge (1 pt, y 5...6), extended under the llama with a rounded end
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 5, width: 14.5, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
        }
        symbol("plus")?.draw(in: NSRect(x: withLlama ? 30.5 : 17.5, y: 10, width: 6.5, height: 6.5))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = appName
    return image
}

/// Width of the menu's custom rows.
let menuWidth: CGFloat = 272

/// "● text" with a small colored dot.
func dotted(_ text: String, dot: NSColor?, size: CGFloat) -> NSAttributedString {
    let line = NSMutableAttributedString()
    if let dot = dot {
        line.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dot,
                                                                   .font: NSFont.systemFont(ofSize: size - 3)]))
    }
    line.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                               .font: NSFont.systemFont(ofSize: size)]))
    return line
}

/// A small status dot that can softly pulse while Ollama is working.
final class DotView: NSView {
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var pulsing = false {
        didSet {
            guard pulsing != oldValue else { return }
            wantsLayer = true
            if pulsing {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.25
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer?.add(pulse, forKey: "pulse")
            } else {
                layer?.removeAnimation(forKey: "pulse")
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// On/off switch: green when on, red when off, orange while it is switching.
final class ColorSwitch: NSControl {
    private(set) var isOn = false
    private var knob: CGFloat = 0  // 0 = left (off), 1 = right (on)
    private var animation: Timer?

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 20) }

    func set(on: Bool, animated: Bool) {
        guard on != isOn || animation == nil && knob != (on ? 1 : 0) else { return }
        isOn = on
        let target: CGFloat = on ? 1 : 0
        animation?.invalidate()
        guard animated else {
            knob = target
            needsDisplay = true
            return
        }
        let start = knob, began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { return timer.invalidate() }
            let t = min(1, (CACurrentMediaTime() - began) / 0.18)
            self.knob = start + (target - start) * CGFloat(t * (2 - t))  // ease out
            self.needsDisplay = true
            if t >= 1 {
                timer.invalidate()
                self.animation = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)  // keeps running while the menu is open
        animation = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 1, dy: (bounds.height - 18) / 2)
        (!isEnabled ? NSColor.systemOrange : isOn ? NSColor.systemGreen : NSColor.systemRed).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let size = track.height - 4
        let knobRect = NSRect(x: track.minX + 2 + (track.width - 4 - size) * knob, y: track.minY + 2,
                              width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Menus deliver mouse-up to custom views reliably, so the switch flips on mouse-up.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    private func flip() {
        set(on: !isOn, animated: true)
        sendAction(action, to: target)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { "Extension on or off" }
    override func accessibilityValue() -> Any? { isOn }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        flip()
        return true
    }
}

/// Top of the menu: the app icon, the name, one status line and the on/off switch.
/// The status line is "Ready", "Off", or what Ollama is doing ("Browsing the web · 2:31").
final class HeaderView: NSView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "ThatPet + Ollama")
    let dot = DotView()
    let status = NSTextField(labelWithString: "")
    let toggle = ColorSwitch()

    init(target: AnyObject, action: Selector, icon image: NSImage? = NSApp?.applicationIconImage) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 50))
        autoresizingMask = [.width]
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        toggle.target = target
        toggle.action = action
        for view in [icon, title, dot, status, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 0),
            dot.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 1),
            dot.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            status.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            status.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            status.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 36),
            toggle.heightAnchor.constraint(equalToConstant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(running: Bool, status text: String, color: NSColor, pulsing: Bool = false, busy: Bool = false) {
        toggle.set(on: running, animated: window != nil)
        toggle.isEnabled = !busy
        icon.alphaValue = running || busy ? 1 : 0.45
        dot.color = color
        dot.pulsing = pulsing
        status.stringValue = text
    }
}

/// A compact line under the header: ThatPet's state and the last reaction, icons first.
final class StatusStrip: NSView {
    let petIcon = NSImageView()
    let petText = NSTextField(labelWithString: "ThatPet")
    let clockIcon = NSImageView()
    let reactionText = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 20))
        autoresizingMask = [.width]
        petIcon.image = symbol("pawprint.fill", size: 10, weight: .semibold)
        clockIcon.image = symbol("clock", size: 10, weight: .medium)
        clockIcon.contentTintColor = .tertiaryLabelColor
        for text in [petText, reactionText] {
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
        }
        for view in [petIcon, petText, clockIcon, reactionText] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            petIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 53),
            petIcon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            petText.leadingAnchor.constraint(equalTo: petIcon.trailingAnchor, constant: 4),
            petText.centerYAnchor.constraint(equalTo: petIcon.centerYAnchor),
            clockIcon.leadingAnchor.constraint(equalTo: petText.trailingAnchor, constant: 12),
            clockIcon.centerYAnchor.constraint(equalTo: petIcon.centerYAnchor),
            reactionText.leadingAnchor.constraint(equalTo: clockIcon.trailingAnchor, constant: 4),
            reactionText.centerYAnchor.constraint(equalTo: petIcon.centerYAnchor),
            reactionText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// pet: "ThatPet", "Not linked" or "ThatPet closed"; color: green, orange or grey.
    func show(pet: String, petColor: NSColor, reaction: String) {
        petText.stringValue = pet
        petIcon.contentTintColor = petColor
        reactionText.stringValue = reaction
        toolTip = "ThatPet: \(pet) · last reaction: \(reaction)"
    }
}

/// A status line in the menu (used for warnings): symbol and label on the left, hint on the right.
final class InfoRow: NSView {
    let symbolView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "")

    init(symbol name: String, label text: String, tint: NSColor = .secondaryLabelColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 22))
        autoresizingMask = [.width]
        symbolView.image = symbol(name, size: 11, weight: .medium)
        symbolView.contentTintColor = tint
        label.stringValue = text
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        value.alignment = .right
        value.lineBreakMode = .byTruncatingTail
        for view in [symbolView, label, value] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(_ text: String, dot: NSColor? = nil) {
        value.attributedStringValue = dotted(text, dot: dot, size: 11)
    }
}
