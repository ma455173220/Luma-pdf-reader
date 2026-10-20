import Foundation

/// The places the reader has jumped away from, so that a jump can be undone and redone.
public struct NavigationHistory<Place: Equatable> {
    public static var limit: Int { 100 }

    private(set) var back: [Place] = []
    private(set) var forward: [Place] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Call just before following a link or any other jump, with where the reader is now.
    public mutating func jumped(from place: Place) {
        if back.last != place { back.append(place) }
        if back.count > NavigationHistory.limit { back.removeFirst(back.count - NavigationHistory.limit) }
        forward.removeAll()
    }

    /// Where to go back to, given where the reader is now. Nil when there is nowhere to go.
    public mutating func goBack(from current: Place) -> Place? {
        guard let place = back.popLast() else { return nil }
        forward.append(current)
        return place
    }

    public mutating func goForward(from current: Place) -> Place? {
        guard let place = forward.popLast() else { return nil }
        back.append(current)
        return place
    }
}
