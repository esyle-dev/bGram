import Foundation
import UIKit

// βeta Features: demo-recording knobs that the ported feature sources reference. In a normal app run
// they stay at their defaults, so the layout is the stock one.

/// Reserved for the concept demo recordings: shrinks the window by this many points (0 = off).
public var conceptsDemoWindowHeightReduction: CGFloat = 0.0
/// Reserved for the concept demo recordings: keeps the bottom of a list pinned while a cell expands.
public var conceptsDemoAnchorBottomOnUpdate = false