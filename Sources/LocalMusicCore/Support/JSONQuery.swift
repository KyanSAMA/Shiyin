import Foundation

/// Dot-path lookup and comparisons over JSONSerialization-compatible values (self-test assertions).
public enum JSONQuery {
    public static func value(at path: String, in root: Any) -> Any? {
        var current: Any? = root
        for key in path.split(separator: ".").map(String.init) {
            switch current {
            case let dict as [String: Any]:
                current = dict[key]
            case let array as [Any]:
                guard let i = Int(key), array.indices.contains(i) else { return nil }
                current = array[i]
            default:
                return nil
            }
        }
        return current
    }
}

public enum Comparison {
    case equals(Any)
    case approx(Double, tolerance: Double)
    case lessThan(Double)
    case greaterThan(Double)
    case contains(Any)

    /// Reads the comparator from a script step: `equals` | `approx`+`tol` | `lt` | `gt` | `contains`.
    public init?(_ step: [String: Any]) {
        if let v = step["equals"] { self = .equals(v) }
        else if let v = Self.number(step["approx"]) { self = .approx(v, tolerance: Self.number(step["tol"]) ?? 0) }
        else if let v = Self.number(step["lt"]) { self = .lessThan(v) }
        else if let v = Self.number(step["gt"]) { self = .greaterThan(v) }
        else if let v = step["contains"] { self = .contains(v) }
        else { return nil }
    }

    public func matches(_ actual: Any?) -> Bool {
        switch self {
        case .equals(let expected):
            guard let actual else { return expected is NSNull }
            return (actual as AnyObject).isEqual(expected)
        case .approx(let expected, let tolerance):
            return Self.number(actual).map { abs($0 - expected) <= tolerance } ?? false
        case .lessThan(let bound):
            return Self.number(actual).map { $0 < bound } ?? false
        case .greaterThan(let bound):
            return Self.number(actual).map { $0 > bound } ?? false
        case .contains(let needle):
            if let s = actual as? String, let n = needle as? String { return s.contains(n) }
            if let a = actual as? [Any] { return a.contains { ($0 as AnyObject).isEqual(needle) } }
            return false
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value, !(value is String) else { return nil }
        return (value as? NSNumber)?.doubleValue
    }
}
