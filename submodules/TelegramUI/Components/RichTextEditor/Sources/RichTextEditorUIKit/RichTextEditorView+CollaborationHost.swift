#if canImport(UIKit)
import UIKit
import RichTextEditorCore

/// Reads a collaboration host needs: which top-level block holds the caret, and where a top-level
/// block is on screen. Both are reads of state the canvas already keeps; no editing logic lives here.
@available(iOS 13.0, *)
public extension RichTextEditorView {
    /// The top-level block the caret (the selection head) is in, or nil when the caret is at a
    /// structural slot between blocks.
    func caretTopLevelBlockID() -> BlockID? {
        let head = self.canvas.canonicalSelection.head.utf16Offset
        let root = DocumentTree.build(from: self.document)
        guard head >= 0, head <= root.nodeSize else {
            return nil
        }
        let resolved = PositionResolver.resolve(head, in: root)
        guard resolved.path.count > 1 else {
            return nil
        }
        return topLevelBlockID(of: resolved.path[1].node)
    }

    /// The frame of a top-level block in this view's coordinate space, or nil when the block is not
    /// in the document.
    func frame(ofTopLevelBlock id: BlockID) -> CGRect? {
        guard let box = self.canvas.boxes.first(where: { $0.id == id }) else {
            return nil
        }
        return self.convert(box.frame, from: self.canvas)
    }

    /// The text line rectangles of a paragraph box, from its layout's selection rects over the whole
    /// text, moved to the box's text origin and then to this view's space.
    func lineRects(ofTopLevelBlock id: BlockID) -> [CGRect] {
        guard let box = self.canvas.boxes.first(where: { $0.id == id }) as? BlockBox else {
            return []
        }
        let origin = box.textOrigin
        var rects: [CGRect]
        if box.textLength == 0 {
            let caret = box.layout.caretRect(atOffset: 0)
            rects = [CGRect(x: caret.minX, y: caret.minY, width: 0.0, height: caret.height)]
        } else {
            rects = box.layout.selectionRects(start: 0, end: box.textLength)
        }
        return rects.map { rect in
            self.convert(rect.offsetBy(dx: origin.x, dy: origin.y), from: self.canvas)
        }
    }

    /// The scroll view the canvas lives in. A view added to it at the top of the content scrolls
    /// with the text; the host reserves the room through `contentMargins.top`.
    var collaborationContentHostView: UIScrollView {
        return self.scrollView
    }
}

private func topLevelBlockID(of node: DocNode) -> BlockID? {
    switch node {
    case let .paragraph(id, _), let .mediaBlock(id, _), let .table(id, _), let .blockQuote(id, _), let .details(id, _), let .mediaAtom(id):
        return id
    case .doc, .text, .row, .cell:
        return nil
    }
}
#endif
