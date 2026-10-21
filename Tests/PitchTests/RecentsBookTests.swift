import CoreGraphics
import Foundation
import Testing

@testable import DisplayCore
@testable import Pitch

/// An in-memory `PresetStoring`. Nothing here touches the real
/// Application Support folder.
private final class FakeStore: PresetStoring, @unchecked Sendable {
    var contents: PresetStore
    var loadError: Error?
    private(set) var saveCount = 0

    init(_ contents: PresetStore = PresetStore()) {
        self.contents = contents
    }

    func load() throws -> PresetStore {
        if let loadError { throw loadError }
        return contents
    }

    func save(_ store: PresetStore) throws {
        saveCount += 1
        contents = store
    }
}

private struct FakeIdentifier: DisplayIdentifying {
    var identities: [CGDirectDisplayID: DisplayIdentity]

    func identity(for id: CGDirectDisplayID) -> DisplayIdentity {
        // An unreadable EDID, which `DisplayIdentity.isUsable` refuses to match
        // on — the right answer for a display the test never described.
        identities[id] ?? DisplayIdentity(uuid: nil, hardwareKey: "0:0:0")
    }
}

private let hd = ModeSignature(
    pointWidth: 1920, pointHeight: 1080,
    pixelWidth: 1920, pixelHeight: 1080,
    refreshMilliHz: 60_000, isSafe: true)

private func signature(width: Int) -> ModeSignature {
    ModeSignature(
        pointWidth: width, pointHeight: 1080,
        pixelWidth: width, pixelHeight: 1080,
        refreshMilliHz: 60_000, isSafe: true)
}

private let studio = DisplayIdentity(uuid: "A1", hardwareKey: "7789:23305:79350")

@Test func recentsSurviveARelaunch() {
    let store = FakeStore()
    let identifier = FakeIdentifier(identities: [1: studio])

    RecentsBook(store: store, identifier: identifier)
        .record(hd, for: 1)
    // A second book over the same file is what a relaunch looks like.
    let afterRelaunch = RecentsBook(store: store, identifier: identifier)

    #expect(afterRelaunch.recents(for: 1) == [hd])
}

@Test func theSameMonitorIsFoundAfterItsDisplayIDChanges() {
    // The whole point of storing an identity: CGDirectDisplayID is reassigned
    // on replug, so the number the dots were recorded under is not the number
    // they must be found under.
    let store = FakeStore()
    RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))
        .record(hd, for: 1)

    let afterReplug = RecentsBook(
        store: store, identifier: FakeIdentifier(identities: [99: studio]))

    #expect(afterReplug.recents(for: 99) == [hd])
}

@Test func aDifferentMonitorDoesNotInheritTheDots() {
    let store = FakeStore()
    RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))
        .record(hd, for: 1)

    let stranger = DisplayIdentity(uuid: "B2", hardwareKey: "1:2:3")
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: stranger]))

    #expect(book.recents(for: 1).isEmpty)
}

@Test func identicalTwinsShowNoDotsRatherThanTheWrongOnes() {
    // Spec §9: a batch of panels can share a serial. Tier 3 would separate
    // them; until it exists, declining is the only honest answer.
    let twin = DisplayIdentity(uuid: nil, hardwareKey: "7789:23305:0")
    let store = FakeStore(
        PresetStore(displays: [
            StoredDisplay(identity: twin, recents: [hd]),
            StoredDisplay(identity: twin, recents: [signature(width: 1280)]),
        ]))
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: twin]))

    #expect(book.recents(for: 1).isEmpty)

    // And recording must not append a third entry that ties with the other two.
    book.record(signature(width: 1600), for: 1)
    #expect(store.contents.displays.count == 2)
}

@Test func aStoreThatCouldNotBeReadIsNeverOverwritten() {
    // A damaged file may still be rescuable by hand. Saving over it would end
    // that, and the only thing lost by not saving is three dots.
    let store = FakeStore()
    store.loadError = DisplayError.storeSchemaUnsupported(version: 99)
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))

    book.record(hd, for: 1)

    #expect(store.saveCount == 0)
}

@Test func recordingHealsAStaleUUID() {
    // Spec §9: the OS recomputes the UUID after some updates. Matching by
    // hardware still works, and the fresh UUID is written back so that tier 1
    // keeps doing the work next time.
    let stale = DisplayIdentity(uuid: "STALE", hardwareKey: "7789:23305:79350")
    let store = FakeStore(
        PresetStore(displays: [
            StoredDisplay(identity: stale, recents: [])
        ]))
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))

    book.record(hd, for: 1)

    #expect(store.contents.displays.first?.identity.uuid == "A1")
}

@Test func theStoredListIsCappedTheSameWayTheInMemoryOneWas() {
    let store = FakeStore()
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))

    for width in [1280, 1440, 1600, 1680, 1920, 2560] {
        book.record(signature(width: width), for: 1)
    }

    #expect(store.contents.displays.first?.recents.count == MenuModel.recentCapacity)
    // Newest first, so the last one recorded leads.
    #expect(store.contents.displays.first?.recents.first == signature(width: 2560))
}

@Test func aBookWithNoStoreStillRemembersForTheSession() {
    // The fallback when the Application Support URL cannot be resolved at all.
    // The dots must still work; they just do not outlive the launch.
    let book = RecentsBook(store: nil, identifier: FakeIdentifier(identities: [1: studio]))

    book.record(hd, for: 1)

    #expect(book.recents(for: 1) == [hd])
}

@Test func aRememberedBrightnessSurvivesARelaunch() {
    let store = FakeStore()
    let identifier = FakeIdentifier(identities: [1: studio])

    RecentsBook(store: store, identifier: identifier).recordBrightness(0.4, for: 1)
    let afterRelaunch = RecentsBook(store: store, identifier: identifier)

    #expect(afterRelaunch.brightness(for: 1) == 0.4)
}

@Test func brightnessIsFoundAgainAfterTheDisplayIDChanges() {
    let store = FakeStore()
    RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))
        .recordBrightness(0.4, for: 1)

    let afterReplug = RecentsBook(
        store: store, identifier: FakeIdentifier(identities: [99: studio]))

    #expect(afterReplug.brightness(for: 99) == 0.4)
}

@Test func recordingBrightnessKeepsTheRecentsOfTheSameDisplay() {
    let store = FakeStore()
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))
    book.record(hd, for: 1)

    book.recordBrightness(0.7, for: 1)
    book.record(signature(width: 1280), for: 1)

    #expect(store.contents.displays.count == 1)
    #expect(book.brightness(for: 1) == 0.7)
    #expect(book.recents(for: 1) == [signature(width: 1280), hd])
}

@Test func aDisplayWithNothingRememberedHasNoBrightness() {
    let book = RecentsBook(
        store: FakeStore(), identifier: FakeIdentifier(identities: [1: studio]))

    #expect(book.brightness(for: 1) == nil)
}

@Test func recordingTheSameBrightnessAgainDoesNotRewriteTheFile() {
    // The slider commits on every release; a value that has not changed is not
    // worth a disk write.
    let store = FakeStore()
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))

    book.recordBrightness(0.4, for: 1)
    book.recordBrightness(0.4, for: 1)

    #expect(store.saveCount == 1)
}

@Test func identicalTwinsNeitherReadNorReceiveABrightness() {
    let twin = DisplayIdentity(uuid: nil, hardwareKey: "7789:23305:0")
    let store = FakeStore(
        PresetStore(displays: [
            StoredDisplay(identity: twin, brightness: 0.2),
            StoredDisplay(identity: twin, brightness: 0.9),
        ]))
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: twin]))

    #expect(book.brightness(for: 1) == nil)
    book.recordBrightness(0.5, for: 1)
    #expect(store.contents.displays.count == 2)
    #expect(store.saveCount == 0)
}

@Test func aStoreThatCouldNotBeReadIsNotOverwrittenByABrightness() {
    let store = FakeStore()
    store.loadError = DisplayError.storeSchemaUnsupported(version: 99)
    let book = RecentsBook(store: store, identifier: FakeIdentifier(identities: [1: studio]))

    book.recordBrightness(0.4, for: 1)

    #expect(store.saveCount == 0)
}
