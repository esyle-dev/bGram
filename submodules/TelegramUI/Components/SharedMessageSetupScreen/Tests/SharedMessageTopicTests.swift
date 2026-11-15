import XCTest
import TelegramCore
import RichTextEditorCore
@testable import SharedMessageSetupScreen

private func paragraph(_ id: String, _ text: String) -> Block {
    return .paragraph(ParagraphBlock(id: BlockID(id), runs: text.isEmpty ? [] : [TextRun(text: text)]))
}

private func document(_ blocks: [Block]) -> Document {
    return Document(blocks: blocks)
}

private let me = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(1))
private let ron = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(2))

private func entry(_ id: Int32, from author: EnginePeer.Id, at time: Int32 = 1000, cloud: Bool = true, _ payload: SharedMessageRoomPayload) -> SharedMessageTopicReplay.Entry {
    return SharedMessageTopicReplay.Entry(messageId: id, isCloud: cloud, authorId: author, timestamp: time, payload: payload)
}

private func setup(_ doc: Document) -> SharedMessageRoomPayload {
    var payload = SharedMessageRoomPayload(kind: .setup)
    payload.document = doc
    return payload
}

private func snapshot(_ doc: Document, lastOpId: Int32, authors: [EnginePeer.Id] = [], changes: Int = 1) -> SharedMessageRoomPayload {
    var payload = SharedMessageRoomPayload(kind: .snapshot)
    payload.document = doc
    payload.lastOpId = lastOpId
    payload.authorIds = authors.map { $0.toInt64() }
    payload.changeCount = changes
    return payload
}

final class SharedMessageRoomPayloadTests: XCTestCase {
    func testTextChangeSendsOnlyTheChangedBlock() {
        let before = document([paragraph("a", "one"), paragraph("b", "two")])
        let after = document([paragraph("a", "one"), paragraph("b", "two more")])
        let op = SharedMessageRoomPayload.op(from: before, to: after, caret: BlockID("b"))
        XCTAssertNotNil(op)
        XCTAssertEqual(op?.blocks?.map { $0.id.rawValue }, ["b"])
        XCTAssertNil(op?.order, "an unchanged order is not sent")
        XCTAssertNil(op?.deleted)
        XCTAssertNil(op?.document)
        XCTAssertEqual(op?.caret, "b")
        XCTAssertEqual(op!.apply(to: before), after)
    }

    func testNoChangeMakesNoOp() {
        let doc = document([paragraph("a", "one")])
        XCTAssertNil(SharedMessageRoomPayload.op(from: doc, to: doc, caret: nil))
    }

    func testInsertDeleteAndReorderRoundTrip() {
        let before = document([paragraph("a", "one"), paragraph("b", "two"), paragraph("c", "three")])
        let inserted = document([paragraph("a", "one"), paragraph("x", "new"), paragraph("b", "two"), paragraph("c", "three")])
        let deleted = document([paragraph("a", "one"), paragraph("c", "three")])
        let reordered = document([paragraph("c", "three"), paragraph("a", "one"), paragraph("b", "two")])
        for target in [inserted, deleted, reordered] {
            let op = SharedMessageRoomPayload.op(from: before, to: target, caret: nil)!
            XCTAssertEqual(op.apply(to: before), target)
        }
        let deleteOp = SharedMessageRoomPayload.op(from: before, to: deleted, caret: nil)!
        XCTAssertEqual(deleteOp.deleted, ["b"])
        XCTAssertNil(deleteOp.blocks)
    }

    func testUnknownBlockIsAppended() {
        // A block the base does not know is new to everyone else: it lands at the end, so an editor
        // must open on the shared ids (the bug of 2026-11-04: fresh local ids doubled every paragraph).
        let base = document([paragraph("shared", "one")])
        var op = SharedMessageRoomPayload(kind: .op)
        op.blocks = [paragraph("local", "one edited")]
        XCTAssertEqual(op.apply(to: base).blocks.map { $0.id.rawValue }, ["shared", "local"])
    }

    func testJSONRoundTripIsCompact() throws {
        let before = document([paragraph("a", "one")])
        let after = document([paragraph("a", "one two")])
        let op = SharedMessageRoomPayload.op(from: before, to: after, caret: BlockID("a"))!
        let data = try XCTUnwrap(SharedMessageRoomPayload.encode(op))
        let decoded = try XCTUnwrap(SharedMessageRoomPayload.decode(data))
        XCTAssertEqual(decoded.kind, .op)
        XCTAssertEqual(decoded.opId, op.opId)
        XCTAssertEqual(decoded.apply(to: before), after)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{"), "a text payload is recognised by its first character")
        XCTAssertFalse(text.contains("\"order\""), "keys are the short coding keys")
    }
}

final class SharedMessageTopicReplayTests: XCTestCase {
    func testSetupThenOpsInServerOrder() {
        let base = document([paragraph("a", "one")])
        let step1 = document([paragraph("a", "one two")])
        let step2 = document([paragraph("a", "one two"), paragraph("b", "three")])
        let entries = [
            entry(1, from: me, setup(base)),
            entry(2, from: ron, at: 1001, SharedMessageRoomPayload.op(from: base, to: step1, caret: BlockID("a"))!),
            entry(3, from: me, at: 1002, SharedMessageRoomPayload.op(from: step1, to: step2, caret: BlockID("b"))!),
        ]
        let result = SharedMessageTopicReplay.replay(entries, accountPeerId: me, fallback: Document())
        XCTAssertEqual(result.document, step2)
        XCTAssertEqual(result.sessionOps.map { $0.messageId }, [2, 3])
        XCTAssertEqual(result.remote[ron]?.caret, BlockID("a"))
        XCTAssertEqual(result.remote[ron]?.lastOpAt, 1001)
        XCTAssertNil(result.remote[me], "the account itself is never a remote presence")
        XCTAssertEqual(result.acknowledgedOpIds, [entries[2].payload.opId!])
    }

    func testHoldMovesTheCaretWithoutAnOp() {
        var hold = SharedMessageRoomPayload(kind: .hold)
        hold.caret = "b"
        let entries = [
            entry(1, from: me, setup(document([paragraph("a", "one"), paragraph("b", "two")]))),
            entry(2, from: ron, at: 1005, hold),
        ]
        let result = SharedMessageTopicReplay.replay(entries, accountPeerId: me, fallback: Document())
        XCTAssertEqual(result.remote[ron]?.caret, BlockID("b"))
        XCTAssertEqual(result.remote[ron]?.caretAt, 1005)
        XCTAssertEqual(result.remote[ron]?.lastOpAt, 0)
        XCTAssertTrue(result.sessionOps.isEmpty)
    }

    func testSnapshotClosesTheSessionAndKeepsLaterOps() {
        let base = document([paragraph("a", "one")])
        let edited = document([paragraph("a", "one two")])
        let afterSnapshot = document([paragraph("a", "one two"), paragraph("b", "late")])
        let entries = [
            entry(1, from: me, setup(base)),
            entry(2, from: ron, at: 1001, SharedMessageRoomPayload.op(from: base, to: edited, caret: nil)!),
            // An op from another client that landed between the snapshot's last op and the snapshot.
            entry(3, from: ron, at: 1002, SharedMessageRoomPayload.op(from: edited, to: afterSnapshot, caret: nil)!),
            entry(4, from: me, at: 1200, snapshot(edited, lastOpId: 2, authors: [ron], changes: 1)),
        ]
        let result = SharedMessageTopicReplay.replay(entries, accountPeerId: me, fallback: Document())
        XCTAssertEqual(result.document, afterSnapshot, "the op after the snapshot's last op is re-applied")
        XCTAssertEqual(result.sessionOps.map { $0.messageId }, [3])
        XCTAssertEqual(result.lastSnapshotLastOpId, 2)
        XCTAssertEqual(result.versions.count, 1)
        XCTAssertEqual(result.versions.first?.id, 4)
        XCTAssertEqual(result.versions.first?.authorIds, [ron])
        XCTAssertEqual(result.versions.first?.document, edited)
    }

    func testDuplicateSnapshotsOfOneSessionMakeOneVersion() {
        let base = document([paragraph("a", "one")])
        let edited = document([paragraph("a", "one two")])
        let entries = [
            entry(1, from: me, setup(base)),
            entry(2, from: ron, SharedMessageRoomPayload.op(from: base, to: edited, caret: nil)!),
            entry(3, from: me, at: 1200, snapshot(edited, lastOpId: 2)),
            entry(4, from: ron, at: 1201, snapshot(edited, lastOpId: 2)),
        ]
        let result = SharedMessageTopicReplay.replay(entries, accountPeerId: me, fallback: Document())
        XCTAssertEqual(result.versions.map { $0.id }, [3])
    }

    func testRestoreOpAndRestoreSnapshot() {
        let base = document([paragraph("a", "one")])
        let edited = document([paragraph("a", "one two")])
        var restore = SharedMessageRoomPayload(kind: .op)
        restore.opId = "r"
        restore.document = base
        restore.restoreOf = 3
        var restoreSnapshot = snapshot(base, lastOpId: 4)
        restoreSnapshot.restoreOf = 3
        let entries = [
            entry(1, from: me, setup(base)),
            entry(2, from: ron, SharedMessageRoomPayload.op(from: base, to: edited, caret: nil)!),
            entry(3, from: me, at: 1200, snapshot(edited, lastOpId: 2)),
            entry(4, from: me, at: 1300, restore),
            entry(5, from: me, at: 1500, restoreSnapshot),
        ]
        let result = SharedMessageTopicReplay.replay(entries, accountPeerId: me, fallback: Document())
        XCTAssertEqual(result.document, base)
        XCTAssertEqual(result.versions.map { $0.id }, [5, 3])
        XCTAssertEqual(result.versions.first?.isRestore, true)
        XCTAssertEqual(result.versions.last?.isRestore, false)
    }

    func testWithoutSetupTheFallbackIsTheBase() {
        let fallback = document([paragraph("a", "one")])
        let result = SharedMessageTopicReplay.replay([], accountPeerId: me, fallback: fallback)
        XCTAssertNil(result.document, "nothing read yet")
        let edited = document([paragraph("a", "one two")])
        let withOp = SharedMessageTopicReplay.replay([entry(2, from: ron, SharedMessageRoomPayload.op(from: fallback, to: edited, caret: nil)!)], accountPeerId: me, fallback: fallback)
        XCTAssertEqual(withOp.document, edited)
    }
}

final class SharedMessageMarkerTests: XCTestCase {
    func testMarkerRoundTripKeepsBodyAndEntities() throws {
        let link = SharedMessageAttribute.Link(roomPeerId: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(77)), topicId: 12, inviteHash: "AbC")
        let attribute = SharedMessageAttribute(title: "Plan", access: .selectedMembers, peerIds: [ron], closeEditing: .inOneWeek, commentsEnabled: false, link: link)
        let markerURL = try XCTUnwrap(attribute.markerURL)
        let body = "Hello 🙂 world"
        let bodyEntities = [MessageTextEntity(range: 0 ..< 5, type: .Bold)]
        let marked = sharedMessageTextWithMarker(title: "Plan", markerURL: markerURL, text: body, entities: bodyEntities)
        XCTAssertEqual(marked.text, "Plan\nHello 🙂 world")
        let stripped = try XCTUnwrap(sharedMessageStrippingMarker(text: marked.text, entities: marked.entities, sharedAt: 5, authorId: me))
        XCTAssertEqual(stripped.text, body)
        XCTAssertEqual(stripped.entities, bodyEntities)
        XCTAssertEqual(stripped.attribute.title, "Plan")
        XCTAssertEqual(stripped.attribute.access, .selectedMembers)
        XCTAssertEqual(stripped.attribute.peerIds, [ron])
        XCTAssertEqual(stripped.attribute.closeEditing, .inOneWeek)
        XCTAssertFalse(stripped.attribute.commentsEnabled)
        XCTAssertEqual(stripped.attribute.link, link)
        XCTAssertEqual(stripped.attribute.activity.sharedAt, 5)
        XCTAssertEqual(stripped.attribute.activity.editorPeerIds, [me])
    }

    func testTitleOnlyMessageHasEmptyBody() throws {
        let link = SharedMessageAttribute.Link(roomPeerId: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(77)), topicId: 12, inviteHash: nil)
        let attribute = SharedMessageAttribute(title: "Plan", access: .admins, peerIds: [], closeEditing: .never, commentsEnabled: true, link: link)
        let marked = sharedMessageTextWithMarker(title: "Plan", markerURL: attribute.markerURL!, text: "", entities: [])
        XCTAssertEqual(marked.text, "Plan")
        let stripped = try XCTUnwrap(sharedMessageStrippingMarker(text: marked.text, entities: marked.entities, sharedAt: 0, authorId: nil))
        XCTAssertEqual(stripped.text, "")
        XCTAssertTrue(stripped.entities.isEmpty)
        XCTAssertNil(stripped.attribute.link?.inviteHash)
    }

    func testMarkerCarriesManualClose() throws {
        let link = SharedMessageAttribute.Link(roomPeerId: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(77)), topicId: 12, inviteHash: nil)
        let open = SharedMessageAttribute(title: "Plan", access: .admins, peerIds: [], closeEditing: .never, commentsEnabled: true, link: link)
        XCTAssertFalse(try XCTUnwrap(open.markerURL).contains("x="))
        var activity = open.activity
        activity.isClosedManually = true
        let closed = open.withUpdatedActivity(activity)
        let marked = sharedMessageTextWithMarker(title: "Plan", markerURL: try XCTUnwrap(closed.markerURL), text: "", entities: [])
        let stripped = try XCTUnwrap(sharedMessageStrippingMarker(text: marked.text, entities: marked.entities, sharedAt: 0, authorId: nil))
        XCTAssertTrue(stripped.attribute.activity.isClosedManually)
        XCTAssertEqual(stripped.attribute.footerState(now: 1), .closed)
    }

    func testMarkerCarriesNotifyAndVersion() throws {
        let link = SharedMessageAttribute.Link(roomPeerId: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(77)), topicId: 12, inviteHash: nil)
        let quiet = SharedMessageAttribute(title: "Plan", access: .admins, peerIds: [], closeEditing: .never, commentsEnabled: true, link: link)
        let quietURL = try XCTUnwrap(quiet.markerURL)
        XCTAssertFalse(quietURL.contains("n="))
        XCTAssertFalse(quietURL.contains("v="))

        let notifying = SharedMessageAttribute(title: "Plan", access: .admins, peerIds: [], closeEditing: .never, commentsEnabled: true, notifyChanges: true, link: link)
        let saved = notifying.withNextVersion(editorIds: [ron, me])
        XCTAssertEqual(saved.version, 1)
        let marked = sharedMessageTextWithMarker(title: "Plan", markerURL: try XCTUnwrap(saved.markerURL), text: "Body", entities: [])
        let stripped = try XCTUnwrap(sharedMessageStrippingMarker(text: marked.text, entities: marked.entities, sharedAt: 0, authorId: nil))
        XCTAssertTrue(stripped.attribute.notifyChanges)
        XCTAssertEqual(stripped.attribute.version, 1)
        XCTAssertEqual(stripped.attribute.versionEditorIds, [ron, me])
        XCTAssertEqual(stripped.text, "Body")
    }

    func testVersionNoticeText() {
        let one = sharedMessageVersionNoticeText(editorNames: ["Ron"], title: "Plan")
        XCTAssertEqual(one.text, "Ron updated \u{00AB}Plan\u{00BB}")
        XCTAssertEqual(one.entities, [MessageTextEntity(range: 0 ..< 3, type: .Bold)])

        let two = sharedMessageVersionNoticeText(editorNames: ["You", "Tom"], title: "Plan")
        XCTAssertEqual(two.text, "You and Tom updated \u{00AB}Plan\u{00BB}")
        XCTAssertEqual(two.entities, [MessageTextEntity(range: 0 ..< 3, type: .Bold), MessageTextEntity(range: 8 ..< 11, type: .Bold)])

        let many = sharedMessageVersionNoticeText(editorNames: ["Milli", "Tom", "Ron"], title: "Plan")
        XCTAssertEqual(many.text, "Milli and 2 others updated \u{00AB}Plan\u{00BB}")
        XCTAssertEqual(many.entities, [MessageTextEntity(range: 0 ..< 5, type: .Bold), MessageTextEntity(range: 10 ..< 18, type: .Bold)])

        // A name that could not be read drops out rather than leaving a gap.
        XCTAssertEqual(sharedMessageVersionNoticeText(editorNames: ["", "Tom"], title: "Plan").text, "Tom updated \u{00AB}Plan\u{00BB}")
    }

    func testOrdinaryLinkIsNotAMarker() {
        let entities = [MessageTextEntity(range: 0 ..< 4, type: .TextUrl(url: "https://example.org"))]
        XCTAssertNil(sharedMessageStrippingMarker(text: "Plan\nbody", entities: entities, sharedAt: 0, authorId: nil))
    }
}

final class SharedMessageVersionDiffTests: XCTestCase {
    func testWordChangeInsideAParagraph() {
        let old = document([paragraph("a", "Wed 19:10 Beaters with Harry and George")])
        let new = document([paragraph("a", "Wed 19:20 Beaters with Fred and George")])
        let lines = SharedMessageVersionDiff.lines(from: old, to: new)
        XCTAssertEqual(lines.count, 1)
        let kinds = lines[0].runs.map { "\($0.kind):\($0.text)" }
        XCTAssertEqual(kinds, ["equal:Wed ", "deleted:19:10", "inserted:19:20", "equal: Beaters with ", "deleted:Harry", "inserted:Fred", "equal: and George"])
    }

    func testAddedAndRemovedParagraphs() {
        let old = document([paragraph("a", "one"), paragraph("b", "two"), paragraph("c", "three")])
        let new = document([paragraph("a", "one"), paragraph("c", "three"), paragraph("d", "four")])
        let lines = SharedMessageVersionDiff.lines(from: old, to: new)
        XCTAssertEqual(lines.map { $0.blockId.rawValue }, ["a", "b", "c", "d"], "a removed paragraph keeps its place after its predecessor")
        XCTAssertTrue(lines[1].isWhollyDeleted)
        XCTAssertTrue(lines[3].isWhollyInserted)
        XCTAssertEqual(lines[0].runs, [SharedMessageVersionDiff.Run(text: "one", kind: .equal)])
    }

    func testAuthorFilterLeavesOtherBlocksUnmarked() {
        let old = document([paragraph("a", "one"), paragraph("b", "two")])
        let new = document([paragraph("a", "one more"), paragraph("b", "two more")])
        let lines = SharedMessageVersionDiff.lines(from: old, to: new, onlyBlocks: [BlockID("b")])
        XCTAssertEqual(lines[0].runs, [SharedMessageVersionDiff.Run(text: "one more", kind: .equal)])
        XCTAssertEqual(lines[1].runs.map { $0.kind }, [.equal, .inserted])
    }

    func testNoPreviousDocumentShowsEverythingAsNew() {
        let new = document([paragraph("a", "one")])
        let lines = SharedMessageVersionDiff.lines(from: nil, to: new)
        XCTAssertTrue(lines[0].isWhollyInserted)
    }

    func testReplayCarriesTheSessionBaseAndAuthorsBlocksIntoTheVersion() {
        let base = document([paragraph("a", "one"), paragraph("b", "two")])
        let edited = document([paragraph("a", "one more"), paragraph("b", "two")])
        let entries = [
            entry(1, from: me, setup(base)),
            entry(2, from: ron, SharedMessageRoomPayload.op(from: base, to: edited, caret: nil)!),
            entry(3, from: me, at: 1200, snapshot(edited, lastOpId: 2, authors: [ron])),
        ]
        let result = SharedMessageTopicReplay.replay(entries, accountPeerId: me, fallback: Document())
        XCTAssertEqual(result.versions.first?.previousDocument, base)
        XCTAssertEqual(result.versions.first?.blocksByAuthor[ron], [BlockID("a")])
    }
}
