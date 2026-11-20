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

    /// One game frame: advances script time (used for animations) and calls `onTick(dt, input)`.
    func tick(dt: Double, input: [String: Any]) {
        guard !failed else { return }
        context.objectForKeyedSubscript("__jjAdvance")?.call(withArguments: [dt])
        call("onTick", [dt, input])
    }

    // MARK: - Time limit

    /// Caps how long any single call into the script may run; past it, JavaScriptCore terminates
    /// the script (an endless loop becomes an error instead of a frozen app). Returns false if this
    /// macOS doesn't offer the capability, in which case `ScriptRunner`'s watchdog still keeps the
    /// UI responsive.
    @discardableResult
    func setTimeLimit(_ seconds: Double) -> Bool {
        guard let setLimit = Self.setExecutionTimeLimit else { return false }
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), seconds, { _, _ in true }, nil)
        return true
    }

    static var canLimitTime: Bool { setExecutionTimeLimit != nil }

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    /// `JSContextGroupSetExecutionTimeLimit` is in JavaScriptCore but not in its public headers,
    /// so it's looked up at runtime and used only if present.
    private static let setExecutionTimeLimit: SetLimit? = {
        guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
              let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

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

      let now = 0; // seconds of game time, advanced by the host every frame
      globalThis.__jjAdvance = (dt) => { now += dt; };

      class Sprite {
        constructor(kind, props) {
          this._p = Object.assign({ x: 0, y: 0, size: 60, rotation: 0, alpha: 1, visible: true, scale: 1 }, props || {});
          this.kind = kind;
          this.removed = false;
          this._anim = null; // { fromX, fromY, start, seconds } while moveTo is running
          this.id = N.create(kind, this._p);
        }
        _set(key, value) {
          this._p[key] = value;
          if (!this.removed) { const change = {}; change[key] = value; N.update(this.id, change); }
        }
        /// Where the sprite is right now: mid-animation this follows the renderer's linear move,
        /// so hit tests match what's on screen rather than the destination.
        _pos() {
          const a = this._anim;
          if (!a) return { x: this._p.x, y: this._p.y };
          const t = a.seconds <= 0 ? 1 : Math.min((now - a.start) / a.seconds, 1);
          if (t >= 1) { this._anim = null; return { x: this._p.x, y: this._p.y }; }
          return { x: a.fromX + (this._p.x - a.fromX) * t, y: a.fromY + (this._p.y - a.fromY) * t };
        }
        /// Setting x or y mid-animation stops the animation where the sprite currently is.
        _setPosition(key, value) {
          if (this._anim) {
            const p = this._pos();
            this._anim = null;
            this._p.x = p.x; this._p.y = p.y;
            this._p[key] = value;
            if (!this.removed) N.update(this.id, { x: this._p.x, y: this._p.y });
          } else {
            this._set(key, value);
          }
        }
        get x() { return this._pos().x; }           set x(v) { this._setPosition("x", v); }
        get y() { return this._pos().y; }           set y(v) { this._setPosition("y", v); }
        get size() { return this._p.size; }         set size(v) { this._set("size", v); }
        get rotation() { return this._p.rotation; } set rotation(v) { this._set("rotation", v); }
        get alpha() { return this._p.alpha; }       set alpha(v) { this._set("alpha", v); }
        get scale() { return this._p.scale; }       set scale(v) { this._set("scale", v); }
        get visible() { return this._p.visible; }   set visible(v) { this._set("visible", v); }
        get text() { return this._p.text; }         set text(v) { this._set("text", String(v)); }
        get color() { return this._p.color; }       set color(v) { this._set("color", v); }
        get z() { return this._p.z; }               set z(v) { this._set("z", v); }
        moveTo(x, y, seconds) {
          const s = seconds === undefined ? 0.3 : Math.max(seconds, 0);
          const p = this._pos();
          this._anim = { fromX: p.x, fromY: p.y, start: now, seconds: s };
          this._p.x = x; this._p.y = y;
          if (!this.removed) N.effect(this.id, "moveTo", { x: x, y: y, seconds: s });
          return this;
        }
        pulse() { if (!this.removed) N.effect(this.id, "pulse", {}); return this; }
        burst() { if (!this.removed) N.effect(this.id, "burst", {}); return this; }
        /// True if a point (e.g. a hand) is within this sprite's radius plus `reach`.
        touches(point, reach) {
          const p = this._pos();
          return Math.hypot(point.x - p.x, point.y - p.y) < this._p.size * this._p.scale / 2 + (reach || 0);
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
