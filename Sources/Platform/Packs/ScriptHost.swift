import Foundation
import JavaScriptCore

/// What a game pack's script can do to the screen and speakers. `ScriptedGameScene` implements it
/// with SpriteKit; tests use a recording fake.
protocol ScriptRenderer: AnyObject {
    var screenSize: CGSize { get }
    /// kind: "emoji", "text", "circle", "rect" or "image". Returns a handle.
    func createNode(kind: String, props: [String: Any]) -> Int
    func updateNode(_ id: Int, props: [String: Any])
    /// effect: "moveTo", "pulse" or "burst".
    func nodeEffect(_ id: Int, effect: String, props: [String: Any])
    func removeNode(_ id: Int)
    func say(_ text: String)
    func playSound(_ name: String)
    func confetti()
    func log(_ message: String)
}

/// Runs one game pack's JavaScript in its own JSContext. The script only sees the `game` API
/// defined in the prelude below: no files, no network, no timers. Errors stop the script and are
/// reported through `lastError` instead of crashing the app.
///
/// Script lifecycle (all optional): `onStart()`, `onTick(dt, input)`, `onPause()`, `onResume()`.
final class ScriptHost {
    private let context: JSContext
    weak var renderer: ScriptRenderer?
    private(set) var lastError: String?

    var failed: Bool { lastError != nil }

    init(renderer: ScriptRenderer) {
        self.renderer = renderer
        context = JSContext()!
        context.name = "Jiggle Jam game"
        context.exceptionHandler = { [weak self] _, exception in
            guard let self, self.lastError == nil, let exception else { return }
            let line = exception.objectForKeyedSubscript("line")?.toInt32() ?? 0
            self.lastError = "Line \(line): \(exception.toString() ?? "error")"
            self.renderer?.log("Script error: \(self.lastError!)")
        }
        installNatives()
        context.evaluateScript(Self.prelude, withSourceURL: URL(string: "jigglejam://prelude.js"))
    }

    /// Loads the pack's main script. Returns false (with `lastError` set) if it fails.
    @discardableResult
    func load(script: String, name: String) -> Bool {
        context.evaluateScript(script, withSourceURL: URL(string: "jigglejam://\(name)"))
        return !failed
    }

    /// Calls a lifecycle function if the script defines it. Arguments are converted to JS values.
    func call(_ function: String, _ arguments: [Any] = []) {
        guard !failed, let fn = context.objectForKeyedSubscript(function), !fn.isUndefined, !fn.isNull else { return }
        fn.call(withArguments: arguments)
    }

    /// Evaluates an expression and returns it (for tests and debugging).
    func evaluate(_ expression: String) -> JSValue? {
        context.evaluateScript(expression)
    }

    // MARK: - Native bridge

    private func installNatives() {
        let native = JSValue(newObjectIn: context)!
        func add(_ name: String, _ block: Any) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        let create: @convention(block) (String, JSValue) -> Int = { [weak self] kind, props in
            self?.renderer?.createNode(kind: kind, props: Self.dictionary(props)) ?? -1
        }
        let update: @convention(block) (Int, JSValue) -> Void = { [weak self] id, props in
            self?.renderer?.updateNode(id, props: Self.dictionary(props))
        }
        let effect: @convention(block) (Int, String, JSValue) -> Void = { [weak self] id, name, props in
            self?.renderer?.nodeEffect(id, effect: name, props: Self.dictionary(props))
        }
        let remove: @convention(block) (Int) -> Void = { [weak self] id in self?.renderer?.removeNode(id) }
        let say: @convention(block) (String) -> Void = { [weak self] text in self?.renderer?.say(text) }
        let sound: @convention(block) (String) -> Void = { [weak self] name in self?.renderer?.playSound(name) }
        let confetti: @convention(block) () -> Void = { [weak self] in self?.renderer?.confetti() }
        let log: @convention(block) (String) -> Void = { [weak self] message in self?.renderer?.log(message) }
        let width: @convention(block) () -> Double = { [weak self] in Double(self?.renderer?.screenSize.width ?? 0) }
        let height: @convention(block) () -> Double = { [weak self] in Double(self?.renderer?.screenSize.height ?? 0) }

        add("create", create); add("update", update); add("effect", effect); add("remove", remove)
        add("say", say); add("sound", sound); add("confetti", confetti); add("log", log)
        add("width", width); add("height", height)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    private static func dictionary(_ value: JSValue) -> [String: Any] {
        guard value.isObject, let dict = value.toDictionary() as? [String: Any] else { return [:] }
        return dict
    }

    /// The API pack scripts program against. Kept small and documented in docs/GAME_PACKS.md.
    static let prelude = #"""
    "use strict";
    var game = (function () {
      const N = __native;
      delete globalThis.__native;

      class Sprite {
        constructor(kind, props) {
          this._p = Object.assign({ x: 0, y: 0, size: 60, rotation: 0, alpha: 1, visible: true, scale: 1 }, props || {});
          this.kind = kind;
          this.removed = false;
          this.id = N.create(kind, this._p);
        }
        _set(key, value) {
          this._p[key] = value;
          if (!this.removed) { const change = {}; change[key] = value; N.update(this.id, change); }
        }
        get x() { return this._p.x; }               set x(v) { this._set("x", v); }
        get y() { return this._p.y; }               set y(v) { this._set("y", v); }
        get size() { return this._p.size; }         set size(v) { this._set("size", v); }
        get rotation() { return this._p.rotation; } set rotation(v) { this._set("rotation", v); }
        get alpha() { return this._p.alpha; }       set alpha(v) { this._set("alpha", v); }
        get scale() { return this._p.scale; }       set scale(v) { this._set("scale", v); }
        get visible() { return this._p.visible; }   set visible(v) { this._set("visible", v); }
        get text() { return this._p.text; }         set text(v) { this._set("text", String(v)); }
        get color() { return this._p.color; }       set color(v) { this._set("color", v); }
        get z() { return this._p.z; }               set z(v) { this._set("z", v); }
        moveTo(x, y, seconds) {
          this._p.x = x; this._p.y = y;
          if (!this.removed) N.effect(this.id, "moveTo", { x: x, y: y, seconds: seconds === undefined ? 0.3 : seconds });
          return this;
        }
        pulse() { if (!this.removed) N.effect(this.id, "pulse", {}); return this; }
        burst() { if (!this.removed) N.effect(this.id, "burst", {}); return this; }
        /// True if a point (e.g. a hand) is within this sprite's radius plus `reach`.
        touches(point, reach) {
          return Math.hypot(point.x - this._p.x, point.y - this._p.y) < this._p.size * this._p.scale / 2 + (reach || 0);
        }
        remove() { if (!this.removed) { this.removed = true; N.remove(this.id); } }
      }

      return Object.freeze({
        get width() { return N.width(); },
        get height() { return N.height(); },
        emoji: (emoji, props) => new Sprite("emoji", Object.assign({}, props, { text: String(emoji) })),
        text: (text, props) => new Sprite("text", Object.assign({ color: "#FFFFFF" }, props, { text: String(text) })),
        circle: (props) => new Sprite("circle", Object.assign({ color: "#FFFFFF" }, props)),
        rect: (props) => new Sprite("rect", Object.assign({ width: 100, height: 100, color: "#FFFFFF" }, props)),
        image: (path, props) => new Sprite("image", Object.assign({}, props, { path: String(path) })),
        say: (text) => N.say(String(text)),
        sound: (name) => N.sound(String(name)),
        confetti: () => N.confetti(),
        log: function () { N.log(Array.prototype.map.call(arguments, String).join(" ")); },
        random: (min, max) => min + Math.random() * (max - min),
        pick: (list) => list[Math.floor(Math.random() * list.length)],
        distance: (a, b) => Math.hypot(a.x - b.x, a.y - b.y),
      });
    })();
    var console = Object.freeze({ log: game.log });
    """#
}
