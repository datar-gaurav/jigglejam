import XCTest

/// Word Train's word lists and puzzles: every word is buildable and every puzzle is fair.
final class WordTrainWordsTests: XCTestCase {
    private typealias Words = WordTrainWords
    private let letters = Set("abcdefghijklmnopqrstuvwxyz")

    func testWordsAreLowercaseWithPicturesAndRightLength() {
        for word in Words.shortFamilies.joined() {
            XCTAssertEqual(word.text.count, 3, word.text)
            XCTAssertTrue(word.text.allSatisfy(letters.contains), word.text)
            XCTAssertFalse(word.picture.isEmpty, word.text)
        }
        for word in Words.longFamilies.joined() {
            XCTAssertEqual(word.text.count, 4, word.text)
            XCTAssertTrue(word.text.allSatisfy(letters.contains), word.text)
        }
    }

    func testNoDuplicateWords() {
        let all = (Words.shortFamilies + Words.longFamilies).joined().map(\.text)
        XCTAssertEqual(all.count, Set(all).count)
    }

    func testEveryLetterHasASpokenName() {
        for letter in letters { XCTAssertNotNil(Words.spokenNames[letter], String(letter)) }
        XCTAssertEqual(Words.spelledOut("cat"), "see, ay, tee… cat!")
    }

    func testPuzzlesAreSolvableAndFair() {
        var rng = SystemRandomNumberGenerator()
        for level in Words.Level.allCases {
            for word in Words.queue(long: level.usesLongWords, using: &rng) {
                let p = Words.makePuzzle(word, level: level, using: &rng)
                let needed = p.missing.map { p.letters[$0] }
                // Every needed letter is on a box, plus the level's distractors, and they fit on screen.
                XCTAssertEqual(p.boxes.count, needed.count + level.distractors, word.text)
                XCTAssertLessThanOrEqual(p.boxes.count, 6)
                var pool = p.boxes
                for l in needed {
                    guard let i = pool.firstIndex(of: l) else { return XCTFail("\(word.text) missing box \(l)") }
                    pool.remove(at: i)
                }
                // Distractors are never letters from the word (so a "wrong" box is clearly wrong).
                for l in pool { XCTAssertFalse(word.text.contains(l), "\(word.text) distractor \(l)") }
                // Missing letters are asked for left to right.
                XCTAssertEqual(p.missing, p.missing.sorted())
            }
        }
    }

    func testLevelsMissTheRightLetters() {
        var rng = SystemRandomNumberGenerator()
        let cat = Words.Word(text: "cat", picture: "🐱")
        XCTAssertEqual(Words.makePuzzle(cat, level: .firstLetter, using: &rng).missing, [0])
        XCTAssertEqual(Words.makePuzzle(cat, level: .oneLetter, using: &rng).missing.count, 1)
        XCTAssertEqual(Words.makePuzzle(cat, level: .wholeWord, using: &rng).missing, [0, 1, 2])
    }

    func testDistractorsAvoidLookAlikes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let extra = Words.distractors(for: "bed", count: 3, using: &rng)
            XCTAssertFalse(extra.contains("d"))
            XCTAssertFalse(extra.contains("b"))
            XCTAssertFalse(extra.contains("e"))
        }
    }

    func testRhymes() {
        XCTAssertTrue(Words.rhymes("cat", "hat"))
        XCTAssertTrue(Words.rhymes("bear", "pear"))
        XCTAssertFalse(Words.rhymes("cat", "dog"))
        XCTAssertFalse(Words.rhymes("cat", "cat"))
    }
}
