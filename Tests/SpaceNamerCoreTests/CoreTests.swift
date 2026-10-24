import CoreGraphics
import Testing
@testable import SpaceNamerCore

// MARK: Parsing

@Suite struct SpaceParserTests {
    @Test func keysSpacesByUUIDAndNumbersDesktops() {
        let parsed = snapshot([rawSpace(1, uuid: "A"), rawSpace(2, uuid: "B"), rawSpace(3, uuid: "C")], current: 2)
        let spaces = parsed.allSpaces
        #expect(spaces.map(\.key) == ["A", "B", "C"])
        #expect(spaces.map(\.desktopNumber) == [1, 2, 3])
        #expect(parsed.displays.first?.currentManagedID == 2)
    }

    @Test func givesTheOriginalDesktopAStableKeyWhenItHasNoUUID() {
        let parsed = snapshot([rawSpace(1, uuid: ""), rawSpace(2, uuid: "B")])
        #expect(parsed.allSpaces.first?.key == "Main/primary")
    }

    @Test func recognisesFullScreenSpaces() {
        let parsed = snapshot([rawSpace(1, uuid: "A"), rawSpace(9, uuid: "F", type: 4)])
        #expect(parsed.allSpaces.map(\.kind) == [.desktop, .fullscreen])
    }

    @Test func emptyInputIsAnEmptySnapshot() {
        #expect(SpaceParser.parse([], activeDisplayID: nil).isEmpty)
    }
}

// MARK: Names

@Suite struct NameStoreTests {
    @Test func namesFollowTheirSpaceWhenSpacesAreReordered() throws {
        let clock = Clock()
        let store = NameStore(persistence: MemoryPersistence(), now: { clock.date })
        let before = snapshot([rawSpace(1, uuid: "A"), rawSpace(2, uuid: "B")])
        store.setName("Mail", for: try #require(before.allSpaces.first))
        store.reconcile(with: before)

        let reordered = snapshot([rawSpace(2, uuid: "B"), rawSpace(1, uuid: "A")])
        store.reconcile(with: reordered)
        #expect(store.name(for: "A") == "Mail")
        #expect(reordered.allSpaces.last?.key == "A")
    }

    @Test func forgetsAClosedSpaceOnlyAfterTheGracePeriod() throws {
        let clock = Clock()
        let store = NameStore(persistence: MemoryPersistence(), now: { clock.date })
        clock.advance(NameStore.reconfigurationQuietPeriod)
        let both = snapshot([rawSpace(1, uuid: "A"), rawSpace(2, uuid: "B")])
        store.setName("Notes", for: try #require(both.allSpaces.last))

        let closed = snapshot([rawSpace(1, uuid: "A")])
        #expect(store.reconcile(with: closed).isEmpty)
        clock.advance(NameStore.removalGracePeriod - 1)
        #expect(store.reconcile(with: closed).isEmpty)
        #expect(store.name(for: "B") == "Notes")

        clock.advance(2)
        #expect(store.reconcile(with: closed) == ["B"])
        #expect(store.name(for: "B") == nil)
    }

    @Test func keepsNamesThroughADisplayReconfiguration() throws {
        let clock = Clock()
        let store = NameStore(persistence: MemoryPersistence(), now: { clock.date })
        let both = snapshot([rawSpace(1, uuid: "A"), rawSpace(2, uuid: "B")])
        store.setName("Notes", for: try #require(both.allSpaces.last))

        store.noteDisplayReconfiguration()
        let shuffled = snapshot([rawSpace(1, uuid: "A")])
        clock.advance(NameStore.removalGracePeriod + 1)
        #expect(store.reconcile(with: shuffled).isEmpty)
        #expect(store.name(for: "B") == "Notes")
    }

    @Test func ignoresAnEmptyLayout() throws {
        let clock = Clock()
        let store = NameStore(persistence: MemoryPersistence(), now: { clock.date })
        store.setName("Code", for: try #require(snapshot([rawSpace(1, uuid: "A")]).allSpaces.first))
        clock.advance(3600)
        #expect(store.reconcile(with: SpacesSnapshot.empty).isEmpty)
        #expect(store.name(for: "A") == "Code")
    }

    @Test func persistsAndReloads() throws {
        let persistence = MemoryPersistence()
        let space = try #require(snapshot([rawSpace(1, uuid: "A")]).allSpaces.first)
        NameStore(persistence: persistence).setName("Design", for: space)
        #expect(NameStore(persistence: persistence).name(for: "A") == "Design")
    }

    @Test func normalizesNames() {
        #expect(NameStore.normalizedName("  Mail \n") == "Mail")
        #expect(NameStore.normalizedName("   ") == nil)
        #expect(NameStore.normalizedName(nil) == nil)
        #expect(NameStore.normalizedName(longName(100))?.count == NameStore.maximumNameLength)
    }

    @Test func aShortcutBelongsToOneSpace() throws {
        let store = NameStore(persistence: MemoryPersistence())
        let spaces = snapshot([rawSpace(1, uuid: "A"), rawSpace(2, uuid: "B")]).allSpaces
        let shortcut = HotKey(keyCode: 18, carbonModifiers: HotKey.carbonModifiers(fromCocoa: HotKey.cocoaControl | HotKey.cocoaOption))
        store.setHotKey(shortcut, for: spaces[0])
        store.setHotKey(shortcut, for: spaces[1])
        #expect(store.hotKey(for: "A") == nil)
        #expect(store.hotKey(for: "B") == shortcut)
    }
}

// MARK: Search, URLs, shortcuts

@Suite struct FuzzyMatcherTests {
    @Test func matchesInOrderAndPrefersPrefixes() throws {
        let prefix = try #require(FuzzyMatcher.match("ma", in: "Mail"))
        let scattered = try #require(FuzzyMatcher.match("ma", in: "Calendar Main"))
        #expect(prefix.score > scattered.score)
        #expect(FuzzyMatcher.match("zz", in: "Mail") == nil)
    }
}

@Suite struct URLCommandTests {
    @Test func parsesCommands() {
        #expect(urlCommand("spacenamer://go/3") == .jumpToPosition(3))
        #expect(urlCommand("spacenamer://jump?position=2") == .jumpToPosition(2))
        #expect(urlCommand("spacenamer://go/Mail") == .jumpToName("Mail"))
        #expect(urlCommand("spacenamer://go?name=Code%20Review") == .jumpToName("Code Review"))
        #expect(urlCommand("spacenamer://next") == .next)
        #expect(urlCommand("spacenamer://previous") == .previous)
        #expect(urlCommand("spacenamer://back") == .back)
        #expect(urlCommand("spacenamer://switcher") == .switcher)
        #expect(urlCommand("spacenamer://rename?name=Inbox") == .rename("Inbox"))
        #expect(urlCommand("spacenamer://settings") == .settings)
    }

    @Test func rejectsOtherSchemesAndUnknownVerbs() {
        #expect(urlCommand("https://example.com/go/1") == nil)
        #expect(urlCommand("spacenamer://explode") == nil)
    }
}

@Suite struct HotKeyTests {
    @Test func describesItself() {
        let cocoa = HotKey.cocoaControl | HotKey.cocoaOption
        let key = HotKey(keyCode: 18, carbonModifiers: HotKey.carbonModifiers(fromCocoa: cocoa))
        #expect(key.displayString == "⌃⌥1")
        #expect(key.cocoaModifiers == cocoa)
        #expect(key.isValidGlobalShortcut)
    }

    @Test func plainKeysAreNotGlobalShortcuts() {
        #expect(!HotKey(keyCode: 0, carbonModifiers: 0).isValidGlobalShortcut)
    }
}

// MARK: Mission Control names

@Suite struct PillLayoutTests {
    private func named(_ center: CGFloat, cover: CGFloat, text: CGFloat) -> PillLayout.Item {
        PillLayout.Item(center: center, cover: cover, fit: PillLayout.Fit(snug: text + 10, comfortable: text + 18))
    }

    private func unnamed(_ center: CGFloat, width: CGFloat) -> PillLayout.Item {
        PillLayout.Item(center: center, cover: width, fit: nil)
    }

    @Test func centresAPillWithRoomToSpare() throws {
        let pills = PillLayout.layout([named(500, cover: 90, text: 100)], within: 0...1000)
        let pill = try #require(pills[0])
        #expect(pill.center == 500)
        #expect(pill.width == 118)
    }

    @Test func keepsCoveringTheDocksLabelWhateverTheName() throws {
        let pills = PillLayout.layout([named(500, cover: 90, text: 20)], within: 0...1000)
        #expect(try #require(pills[0]).width == 90)
    }

    @Test func movesALongNameIntoTheRoomBesideIt() throws {
        // Eleven desktops on a 1800 pt display: a long tenth name between a named ninth
        // and an unnamed eleventh, with little room on the left and more on the right.
        let items = [named(1192.5, cover: 90, text: 55), named(1295.5, cover: 96, text: 106), unnamed(1400.5, width: 72)]
        let pills = PillLayout.layout(items, within: 6...1794)
        let ninth = try #require(pills[0]), tenth = try #require(pills[1])
        #expect(tenth.width >= 116)
        #expect(tenth.center > 1295.5)
        #expect(tenth.center - tenth.width / 2 >= ninth.center + ninth.width / 2 + PillLayout.gap - 0.01)
        #expect(tenth.center + tenth.width / 2 <= 1400.5 - 36 - PillLayout.clearance + 0.01)
        #expect(pills[2] == nil)
    }

    @Test func neighboursShareTheRoomBetweenThem() throws {
        let pills = PillLayout.layout([named(100, cover: 80, text: 150), named(200, cover: 80, text: 150)], within: 0...300)
        let first = try #require(pills[0]), second = try #require(pills[1])
        #expect(abs(first.width - second.width) < 0.01)
        #expect(first.center + first.width / 2 + PillLayout.gap <= second.center - second.width / 2 + 0.01)
        #expect(first.center < 100 && second.center > 200)
    }

    @Test func collidingCoversShrinkWithoutOverlapping() throws {
        let pills = PillLayout.layout([named(100, cover: 80, text: 20), named(170, cover: 80, text: 20)], within: 0...300)
        let first = try #require(pills[0]), second = try #require(pills[1])
        #expect(abs(first.center + first.width / 2 + PillLayout.gap - (second.center - second.width / 2)) < 0.01)
    }

    @Test func staysInsideTheBar() throws {
        let pills = PillLayout.layout([named(50, cover: 60, text: 120)], within: 6...1000)
        let pill = try #require(pills[0])
        #expect(pill.center - pill.width / 2 >= 6 - 0.01)
        #expect(pill.width >= 130)
    }
}

