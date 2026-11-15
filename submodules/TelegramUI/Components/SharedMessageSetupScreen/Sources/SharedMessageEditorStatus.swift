import Foundation

/// The forms the editor header's "is editing" line can take, in order of preference: the header
/// shows the first that fits beside the history button, and the count form is always last because
/// it is the shortest.
enum SharedMessageEditingStatusShape: Equatable {
    /// "Ron is editing"
    case one(String)
    /// "Milli and Tom are editing"
    case two(String, String)
    /// "Milli and 2 others are editing"
    case oneAndOthers(String, Int)
    /// "12 users editing"
    case count(Int)
}

/// `names` are the known names of the people editing, in order; `count` is how many are editing,
/// which can exceed the names when a person is not loaded yet. An empty count yields nothing.
func sharedMessageEditingStatusShapes(names: [String], count: Int) -> [SharedMessageEditingStatusShape] {
    let names = names.filter { !$0.isEmpty }
    guard count > 0 else {
        return []
    }
    var shapes: [SharedMessageEditingStatusShape] = []
    if count == 1, let first = names.first {
        shapes.append(.one(first))
    } else if count == 2, names.count >= 2 {
        shapes.append(.two(names[0], names[1]))
    } else if count >= 2, let first = names.first {
        shapes.append(.oneAndOthers(first, count - 1))
    }
    shapes.append(.count(count))
    return shapes
}
