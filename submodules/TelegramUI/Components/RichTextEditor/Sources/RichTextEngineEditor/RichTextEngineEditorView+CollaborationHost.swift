#if canImport(UIKit)
import UIKit
import RichTextEditorCore
import RichTextEditorUIKit

/// The same two reads the legacy façade answers for a collaboration host, on the engine editor.
@available(iOS 18.4, *)
extension RichTextEngineEditorView {
    /// The block the caret is in. For a nested block this is the innermost block, which is what a
    /// paragraph lock wants to know.
    public func caretTopLevelBlockID() -> BlockID? {
        return self.blockRelativeLocation(forFlatOffset: self.composerSelectedRange.location)?.0
    }

    /// The frame of a block in this view's coordinate space. Reads the engine's own frame for the
    /// role carrying the id, so a nested block answers too.
    public func frame(ofTopLevelBlock id: BlockID) -> CGRect? {
        guard let index = self.currentRoles.firstIndex(where: { $0.blockID == id }) else {
            return nil
        }
        let frame = self.engine.id_frameForBlock(at: UInt(index))
        guard !frame.isNull, frame.width > 0.0, frame.height > 0.0 else {
            return nil
        }
        return self.convert(frame, from: self.engine)
    }

    /// The text line rectangles of the engine block carrying the id: the engine's rects for the
    /// block's whole canonical range, converted from the engine's space.
    public func lineRects(ofTopLevelBlock id: BlockID) -> [CGRect] {
        guard let index = self.currentRoles.firstIndex(where: { $0.blockID == id }) else {
            return []
        }
        let identifiers = self.engine.tgid_blockIdentifiers
        let blocks = self.engine.attributedBlocks
        guard index < identifiers.count, index < blocks.count, let start = self.canonicalStart(ofBlock: identifiers[index]) else {
            return []
        }
        let length = blocks[index].length
        if length == 0 {
            let frame = self.engine.id_frameForBlock(at: UInt(index))
            guard !frame.isNull else {
                return []
            }
            return [self.convert(CGRect(x: frame.minX, y: frame.minY, width: 0.0, height: frame.height), from: self.engine)]
        }
        return self.engine.id_rects(forCanonicalRange: NSRange(location: start, length: length)).map { value in
            self.convert(value.cgRectValue, from: self.engine)
        }
    }

    /// The engine's own scroll view; its content is where the document is laid out.
    public var collaborationContentHostView: UIScrollView {
        return self.engine
    }
}
#endif
