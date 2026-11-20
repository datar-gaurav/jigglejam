import SpriteKit
import AppKit

/// In-game look, matching the menu: rounded system type with soft shadows, frosted pills,
/// colored banners and gradient backdrops.
enum HUDStyle {
    static func font(_ size: CGFloat, weight: NSFont.Weight = .heavy) -> NSFont {
        let base = NSFont.systemFont(ofSize: max(size, 1), weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: max(size, 1)) ?? base
    }

    static let panelFill = NSColor(white: 0.06, alpha: 0.55)
    static let panelStroke = NSColor(white: 1, alpha: 0.18)
}

/// An `SKLabelNode` drawn in the rounded system font with a soft shadow, so text stays readable
/// over any camera picture or bright scenery. Use it like a normal label (text, fontSize, fontColor).
final class RoundedLabel: SKLabelNode {
    var weight: NSFont.Weight = .heavy { didSet { refresh() } }
    var shadowed = true { didSet { refresh() } }

    private var currentText: String?
    private var currentSize: CGFloat = 32
    private var currentColor: NSColor = .white
    private var refreshing = false

    override init() {
        super.init()
        verticalAlignmentMode = .center
        horizontalAlignmentMode = .center
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    convenience init(_ text: String, size: CGFloat, weight: NSFont.Weight = .heavy) {
        self.init()
        self.weight = weight
        currentSize = size
        currentText = text
        refresh()
    }

    override var text: String? {
        didSet { if !refreshing { currentText = text; refresh() } }
    }

    override var fontSize: CGFloat {
        didSet { if !refreshing { currentSize = fontSize; refresh() } }
    }

    override var fontColor: NSColor? {
        didSet { if !refreshing { currentColor = fontColor ?? .white; refresh() } }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: HUDStyle.font(currentSize, weight: weight),
            .foregroundColor: currentColor,
        ]
        if shadowed {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowOffset = CGSize(width: 0, height: -currentSize * 0.04)
            shadow.shadowBlurRadius = currentSize * 0.14
            attributes[.shadow] = shadow
        }
        attributedText = NSAttributedString(string: currentText ?? "", attributes: attributes)
    }
}

/// A frosted capsule with text, e.g. a score ("⭐️ 12"), a level, or a hint.
final class HUDPill: SKNode {
    private let background = SKShapeNode()
    let label = RoundedLabel("", size: 30)
    private var tint: NSColor?

    var text: String {
        get { label.text ?? "" }
        set { label.text = newValue; resize() }
    }

    /// Pill height in points; the text scales with it.
    var height: CGFloat = 60 {
        didSet { label.fontSize = height * 0.52; resize() }
    }

    init(_ text: String, height: CGFloat = 60, tint: NSColor? = nil) {
        self.tint = tint
        super.init()
        background.fillColor = tint?.withAlphaComponent(0.9) ?? HUDStyle.panelFill
        background.strokeColor = tint == nil ? HUDStyle.panelStroke : NSColor.white.withAlphaComponent(0.35)
        background.lineWidth = 1.5
        addChild(background)
        addChild(label)
        label.text = text
        self.height = height
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func resize() {
        let width = max(label.frame.width + height * 0.9, height * 1.6)
        background.path = CGPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                                 cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
    }

    /// A quick bounce, e.g. when the score changes.
    func pulse() {
        removeAction(forKey: "pulse")
        run(.sequence([.scale(to: 1.18, duration: 0.09), .scale(to: 1, duration: 0.18)]), withKey: "pulse")
    }
}

extension GameScene {
    /// The standard score pill, top center.
    func makeScorePill(_ text: String) -> HUDPill {
        let pill = HUDPill(text)
        pill.zPosition = 40
        return pill
    }

    func placeScorePill(_ pill: HUDPill) {
        pill.height = size.height * 0.1
        pill.position = CGPoint(x: size.width / 2, y: size.height - size.height * 0.095)
    }

    /// A colored banner for big moments ("You made it!", "Level 2!").
    func makeBanner(_ text: String, color: NSColor, height relative: CGFloat = 0.12) -> SKNode {
        let node = SKNode()
        let height = size.height * relative
        let label = RoundedLabel(text, size: height * 0.55)
        let width = label.frame.width + height * 1.1
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)

        let glow = SKShapeNode(path: CGPath(roundedRect: rect.insetBy(dx: -height * 0.12, dy: -height * 0.12),
                                            cornerWidth: height * 0.62, cornerHeight: height * 0.62, transform: nil))
        glow.fillColor = color.withAlphaComponent(0.35)
        glow.strokeColor = .clear
        node.addChild(glow)

        let pill = SKShapeNode(path: CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        pill.fillColor = color
        pill.strokeColor = NSColor.white.withAlphaComponent(0.45)
        pill.lineWidth = 2
        node.addChild(pill)

        let shine = SKShapeNode(path: CGPath(roundedRect: CGRect(x: rect.minX + height * 0.3, y: height * 0.08,
                                                                 width: width - height * 0.6, height: height * 0.32),
                                             cornerWidth: height * 0.16, cornerHeight: height * 0.16, transform: nil))
        shine.fillColor = NSColor.white.withAlphaComponent(0.18)
        shine.strokeColor = .clear
        node.addChild(shine)

        node.addChild(label)
        node.zPosition = 60
        return node
    }

    /// A full-scene vertical gradient (top to bottom), for skies and fields.
    func makeGradientBackdrop(top: NSColor, bottom: NSColor) -> SKSpriteNode {
        let image = NSImage(size: CGSize(width: 4, height: 256), flipped: false) { rect in
            NSGradient(starting: bottom, ending: top)?.draw(in: rect, angle: 90)
            return true
        }
        let sprite = SKSpriteNode(texture: SKTexture(image: image))
        sprite.anchorPoint = .zero
        sprite.size = size
        sprite.zPosition = -100
        return sprite
    }
}
