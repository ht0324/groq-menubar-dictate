import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class SoundCuePlayerTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testPreparationDoesNotPlayUntilRecordingIsReady() async {
        let playback = PlaybackProbe(blockPreparation: true)
        let sounds = SoundCuePlayer(makePlayer: { playback }, shouldPlayAudibleCue: { true })
        sounds.preparePing()
        await fulfillment(of: [playback.started], timeout: 2)
        XCTAssertEqual(playback.events, ["prepare"])

        sounds.playPing()
        // Scheduling the cue returns even while hardware preparation is blocked.
        XCTAssertEqual(playback.events, ["prepare"])
        playback.releasePreparation()
        await fulfillment(of: [playback.played], timeout: 2)
        XCTAssertEqual(playback.events, ["prepare", "ready", "play"])
        sounds.cancelPing()
        await fulfillment(of: [playback.stopped], timeout: 2)
    }

    @MainActor
    func testCancellationDuringPreparationReleasesPlayerWithoutLateCue() async {
        let playback = PlaybackProbe(blockPreparation: true)
        let sounds = SoundCuePlayer(makePlayer: { playback }, shouldPlayAudibleCue: { true })
        sounds.playPing()
        await fulfillment(of: [playback.started], timeout: 2)

        sounds.cancelPing()
        playback.releasePreparation()
        await fulfillment(of: [playback.stopped], timeout: 2)
        XCTAssertEqual(playback.events, ["prepare", "ready", "stop"])
    }

    @MainActor
    func testOutputPolicyIsRecheckedAfterPreparation() async {
        let playback = PlaybackProbe(blockPreparation: true)
        let outputPolicy = OutputPolicyProbe()
        let sounds = SoundCuePlayer(makePlayer: { playback }, shouldPlayAudibleCue: { outputPolicy.allowed })
        sounds.preparePing()
        await fulfillment(of: [playback.started], timeout: 2)

        outputPolicy.allowed = false
        playback.releasePreparation()
        sounds.playPing()
        await fulfillment(of: [playback.stopped], timeout: 2)
        XCTAssertFalse(playback.events.contains("play"))
    }

    @MainActor
    func testSuppressedOutputDoesNotPrepareHardware() async {
        let playback = PlaybackProbe()
        let sounds = SoundCuePlayer(makePlayer: { playback }, shouldPlayAudibleCue: { false })
        sounds.preparePing()
        sounds.playPing()
        XCTAssertEqual(playback.events, [])
    }

    @MainActor
    func testNewCueDoesNotWaitForCancelledPreparation() async {
        let oldPlayback = PlaybackProbe(blockPreparation: true)
        let newPlayback = PlaybackProbe()
        let players = PlaybackSequence([oldPlayback, newPlayback])
        let sounds = SoundCuePlayer(makePlayer: { players.next() }, shouldPlayAudibleCue: { true })
        sounds.playPing()
        await fulfillment(of: [oldPlayback.started], timeout: 2)

        sounds.cancelPing()
        sounds.preparePing()
        sounds.playPing()
        await fulfillment(of: [newPlayback.played], timeout: 2)

        oldPlayback.releasePreparation()
        await fulfillment(of: [oldPlayback.stopped], timeout: 2)
        XCTAssertEqual(oldPlayback.events, ["prepare", "ready", "stop"])
        XCTAssertEqual(newPlayback.events, ["prepare", "ready", "play"])
        sounds.cancelPing()
        await fulfillment(of: [newPlayback.stopped], timeout: 2)
    }
}

@MainActor
private final class OutputPolicyProbe {
    var allowed = true
}

private final class PlaybackProbe: SoundCuePlayback, @unchecked Sendable {
    let started = XCTestExpectation(description: "Preparation started")
    let played = XCTestExpectation(description: "Player played")
    let stopped = XCTestExpectation(description: "Player stopped")
    private let condition = NSCondition()
    private var preparationReleased: Bool
    private var recordedEvents: [String] = []

    init(blockPreparation: Bool = false) {
        preparationReleased = !blockPreparation
    }

    var events: [String] {
        condition.lock()
        defer { condition.unlock() }
        return recordedEvents
    }

    func prepareToPlay() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        recordedEvents.append("prepare")
        started.fulfill()
        let deadline = Date().addingTimeInterval(5)
        while !preparationReleased {
            guard condition.wait(until: deadline) else { return false }
        }
        recordedEvents.append("ready")
        return true
    }

    func releasePreparation() {
        condition.lock()
        preparationReleased = true
        condition.broadcast()
        condition.unlock()
    }

    func play() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        recordedEvents.append("play")
        played.fulfill()
        return true
    }

    func stop() {
        condition.lock()
        recordedEvents.append("stop")
        condition.unlock()
        stopped.fulfill()
    }
}

private final class PlaybackSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var players: [PlaybackProbe]

    init(_ players: [PlaybackProbe]) {
        self.players = players
    }

    func next() -> PlaybackProbe? {
        lock.lock()
        defer { lock.unlock() }
        return players.isEmpty ? nil : players.removeFirst()
    }
}
