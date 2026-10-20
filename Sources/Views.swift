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
let menuWidth: CGFloat = 320

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

/// Soft rounded tile behind the icon, like the modules in Control Center.
final class TileView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 9
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}

/// On/off switch: green when on, red when off, orange while it is switching.
final class ColorSwitch: NSControl {
    private(set) var isOn = false
    private var knob: CGFloat = 0  // 0 = left (off), 1 = right (on)
    private var animation: Timer?

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 42, height: 24) }

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
        let track = NSRect(x: 1, y: (bounds.height - 22) / 2, width: bounds.width - 2, height: 22)
        (!isEnabled ? NSColor.systemOrange : isOn ? NSColor.systemGreen : NSColor.systemRed).setFill()
        NSBezierPath(roundedRect: track, xRadius: 11, yRadius: 11).fill()
        let size: CGFloat = 18
        let knobRect = NSRect(x: track.minX + 2 + (track.width - 4 - size) * knob, y: track.minY + 2,
                              width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
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

/// Top of the menu: icon on a tile, name, status with a colored dot, and an on/off switch.
final class HeaderView: NSView {
    let tile = TileView()
    let icon = NSImageView(image: extensionIcon())
    let title = NSTextField(labelWithString: appName)
    let status = NSTextField(labelWithString: "")
    let toggle = ColorSwitch()
    lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: icon.image?.size.width ?? 24)

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 60))
        autoresizingMask = [.width]
        icon.contentTintColor = .labelColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 11)
        toggle.target = target
        toggle.action = action
        for view in [tile, icon, title, status, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.heightAnchor.constraint(equalToConstant: 34),
            tile.widthAnchor.constraint(equalTo: icon.widthAnchor, constant: 16),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 11),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 42),
            toggle.heightAnchor.constraint(equalToConstant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(running: Bool, busy: String? = nil) {
        icon.image = extensionIcon()
        iconWidth.constant = icon.image?.size.width ?? 24
        toggle.set(on: running, animated: window != nil)
        toggle.isEnabled = busy == nil
        icon.alphaValue = running ? 1 : 0.4
        status.attributedStringValue = dotted(
            busy ?? (running ? "On · ThatPet reacts to Ollama" : "Off · ThatPet ignores Ollama"),
            dot: busy != nil ? .systemOrange : running ? .systemGreen : .systemRed, size: 11)
    }
}

/// A status line in the menu: symbol and label on the left, value on the right.
final class InfoRow: NSView {
    let symbolView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "")

    init(symbol name: String, label text: String, tint: NSColor = .secondaryLabelColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 24))
        autoresizingMask = [.width]
        symbolView.image = symbol(name, size: 12, weight: .medium)
        symbolView.contentTintColor = tint
        label.stringValue = text
        label.font = .menuFont(ofSize: 13)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingTail
        for view in [symbolView, label, value] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setSymbol(_ name: String) {
        symbolView.image = symbol(name, size: 12, weight: .medium)
    }

    func set(_ text: String, dot: NSColor? = nil) {
        value.attributedStringValue = dotted(text, dot: dot, size: 13)
    }
}
