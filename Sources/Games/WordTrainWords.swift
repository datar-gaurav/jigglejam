import Foundation

/// Words, letters and puzzles for Word Train. Pure logic (no SpriteKit) so it can be unit tested.
enum WordTrainWords {
    struct Word: Equatable {
        let text: String     // lowercase a–z
        let picture: String  // an emoji that clearly shows the word
    }

    /// Short words in rhyming families, so a rhyme often comes next (cat, hat, bat…).
    /// Every picture should be something a 4-year-old names the same way without help.
    static let shortFamilies: [[Word]] = [
        [w("cat", "🐱"), w("hat", "🎩"), w("bat", "🦇"), w("rat", "🐀")],
        [w("dog", "🐶"), w("log", "🪵")],
        [w("fox", "🦊"), w("box", "📦")],
        [w("hen", "🐔"), w("pen", "🖊️"), w("ten", "🔟")],
        [w("bug", "🐛"), w("hug", "🤗"), w("mug", "☕️")],
        [w("van", "🚐"), w("fan", "🪭"), w("pan", "🍳"), w("can", "🥫")],
        [w("cap", "🧢"), w("map", "🗺️")],
        [w("bed", "🛏️"), w("red", "🔴")],
        [w("nut", "🥜"), w("hut", "🛖")],
        [w("egg", "🥚"), w("leg", "🦵")],
        [w("car", "🚗"), w("jar", "🫙")],
        [w("sun", "☀️")], [w("pig", "🐷")], [w("cup", "🥤")], [w("bus", "🚌")], [w("cow", "🐄")],
        [w("bee", "🐝")], [w("ant", "🐜")], [w("bag", "👜")], [w("web", "🕸️")],
    ]

    /// Four-letter words for the last level.
    static let longFamilies: [[Word]] = [
        [w("cake", "🎂")],
        [w("bear", "🐻"), w("pear", "🍐")],
        [w("boat", "⛵️"), w("goat", "🐐")],
        [w("sock", "🧦"), w("rock", "🪨")],
        [w("frog", "🐸")], [w("fish", "🐟")], [w("duck", "🦆")], [w("ship", "🚢")], [w("star", "⭐️")],
        [w("ball", "⚽️")], [w("tree", "🌳")], [w("moon", "🌙")], [w("milk", "🥛")], [w("lion", "🦁")],
        [w("bird", "🐦")], [w("crab", "🦀")], [w("drum", "🥁")], [w("kite", "🪁")], [w("doll", "🪆")],
    ]

    private static func w(_ text: String, _ picture: String) -> Word { Word(text: text, picture: picture) }

    // MARK: - Letter names

    /// How to say each letter's *name* so the speech voice gets it right on its own
    /// ("a" alone is often read as "uh", "c" can come out oddly).
    static let spokenNames: [Character: String] = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "eff", "g": "jee",
        "h": "aitch", "i": "eye", "j": "jay", "k": "kay", "l": "ell", "m": "em", "n": "en",
        "o": "oh", "p": "pee", "q": "cue", "r": "ar", "s": "ess", "t": "tee", "u": "you",
        "v": "vee", "w": "double you", "x": "ex", "y": "why", "z": "zee",
    ]

    static func spoken(_ letter: Character) -> String { spokenNames[letter] ?? String(letter) }

    /// The word spelled out and then read: "see, ay, tee… cat!"
    static func spelledOut(_ word: String) -> String {
        word.map { spoken($0) }.joined(separator: ", ") + "… \(word)!"
    }

    // MARK: - Levels and puzzles

    enum Level: Int, CaseIterable {
        case firstLetter = 1   // c _ _ is missing only the first letter: "cat starts with c"
        case oneLetter         // one letter missing anywhere, often the middle vowel
        case wholeWord         // build the whole word, left to right
        case bigWords          // four-letter words, built whole

        var next: Level? { Level(rawValue: rawValue + 1) }
        var usesLongWords: Bool { self == .bigWords }
        /// Wrong letters floating among the right ones.
        var distractors: Int {
            switch self { case .firstLetter, .oneLetter: 2; case .wholeWord, .bigWords: 1 }
        }
    }

    /// Words finished at one level before moving on to the next.
    static let wordsPerLevel = 5

    struct Puzzle: Equatable {
        let word: Word
        /// Indices of the letters the child adds, in the order they're asked for (left to right).
        let missing: [Int]
        /// Letters on the floating boxes: the missing letters plus distractors, shuffled.
        let boxes: [Character]
        var letters: [Character] { Array(word.text) }
    }

    static func makePuzzle<G: RandomNumberGenerator>(_ word: Word, level: Level, using rng: inout G) -> Puzzle {
        let letters = Array(word.text)
        let missing: [Int]
        switch level {
        case .firstLetter:
            missing = [0]
        case .oneLetter:
            // Favor the middle vowel: it's the hardest part of a short word to hear.
            let vowels = letters.indices.filter { "aeiou".contains(letters[$0]) && $0 > 0 }
            if let v = vowels.first, Int.random(in: 0..<3, using: &rng) < 2 {
                missing = [v]
            } else {
                missing = [Int.random(in: 0..<letters.count, using: &rng)]
            }
        case .wholeWord, .bigWords:
            missing = Array(letters.indices)
        }
        let needed = missing.map { letters[$0] }
        let extra = distractors(for: word.text, count: level.distractors, using: &rng)
        return Puzzle(word: word, missing: missing, boxes: (needed + extra).shuffled(using: &rng))
    }

    /// Easy-to-tell-apart letters that aren't in the word. Pairs little kids mix up (b/d, p/q,
    /// m/w, n/u) are kept apart from the word's own letters so the "wrong" box is clearly wrong.
    static func distractors<G: RandomNumberGenerator>(for word: String, count: Int, using rng: inout G) -> [Character] {
        let confusable: [Character: Character] = ["b": "d", "d": "b", "p": "q", "q": "p", "m": "w", "w": "m", "n": "u", "u": "n"]
        let inWord = Set(word)
        let avoid = inWord.union(inWord.compactMap { confusable[$0] })
        let pool = Array("abcdefghijklmnoprstuvwxyz").filter { !avoid.contains($0) }
        return Array(pool.shuffled(using: &rng).prefix(count))
    }

    /// The order words come in: families shuffled, so rhyming words come one after another.
    static func queue<G: RandomNumberGenerator>(long: Bool, using rng: inout G) -> [Word] {
        (long ? longFamilies : shortFamilies).filter { !$0.isEmpty }.shuffled(using: &rng)
            .flatMap { $0.shuffled(using: &rng) }
    }

    /// True when two words rhyme in the simple "same ending" sense (cat / hat).
    static func rhymes(_ a: String, _ b: String) -> Bool {
        a != b && a.count >= 3 && b.count >= 3 && a.suffix(a.count - 1) == b.suffix(b.count - 1)
    }
}
