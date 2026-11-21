import SwiftUI

/// The games that ship as Swift code. Everything else comes in as game packs (see docs/GAME_PACKS.md).
/// To add a built-in game: write a `GameScene` subclass in this folder and add an entry here.
enum BuiltInGames {
    static let all: [GameEntry] = [
        GameEntry(
            id: "bubblePop", title: "Bubble Pop", emoji: "🫧", color: .pink,
            showsCamera: true, needsFullBody: true,
            setupInstruction: "Show me your hands and your feet!",
            setupRequirements: [.seen, .hands, .feet], pack: nil,
            makeScene: { BubbleScene(size: CGSize(width: 1280, height: 720)) }
        ),
        GameEntry(
            id: "freezeDance", title: "Freeze Dance", emoji: "🥶", color: .blue,
            showsCamera: true, needsFullBody: true,
            setupInstruction: "Stand back so I can see all of you!",
            setupRequirements: [.seen, .wholeBody], pack: nil,
            makeScene: { FreezeDanceScene(size: CGSize(width: 1280, height: 720)) }
        ),
        GameEntry(
            id: "rocketJump", title: "Rocket Jump", emoji: "🚀", color: .orange,
            showsCamera: true, needsFullBody: true,
            setupInstruction: "Stand back, feet on the floor, ready to jump!",
            setupRequirements: [.seen, .wholeBody, .feet], pack: nil,
            makeScene: { RocketJumpScene(size: CGSize(width: 1280, height: 720)) }
        ),
        GameEntry(
            id: "driving", title: "Vroom Vroom", emoji: "🚗", color: .green,
            showsCamera: false, needsFullBody: false,
            setupInstruction: "Hold your plate with both hands, nice and flat!",
            setupRequirements: [.bothHands, .wheelLevel], pack: nil,
            makeScene: { DrivingScene(size: CGSize(width: 1280, height: 720)) }
        ),
        GameEntry(
            id: "foxTrail", title: "Fox Trail", emoji: "🦊", color: .purple,
            showsCamera: false, needsFullBody: true,
            setupInstruction: "Stand back so I can see your knees and feet!",
            setupRequirements: [.seen, .knees, .feet], pack: nil,
            makeScene: { FoxTrailScene(size: CGSize(width: 1280, height: 720)) }
        ),
        GameEntry(
            id: "gardenGuard", title: "Garden Guard", emoji: "🌻", color: .mint,
            showsCamera: false, needsFullBody: true,
            setupInstruction: "Stand back and wave your hands up high!",
            setupRequirements: [.seen, .hands, .feet], pack: nil,
            makeScene: { GardenGuardScene(size: CGSize(width: 1280, height: 720)) }
        ),
    ]
}
