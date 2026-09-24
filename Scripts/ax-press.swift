// Activates an element of the running LocalMusic through the Accessibility API, without moving the user's mouse:
// finds the first element whose title/description/value equals (else starts with) the argument, then selects the nearest row or
// presses the nearest pressable ancestor. Needs the terminal's Accessibility grant.
// Usage: swift Scripts/ax-press.swift 暂停        (exit 1: not found / no action, 2: app not running)
import AppKit
import ApplicationServices

let needle = CommandLine.arguments.dropFirst().first ?? ""
// Match the executable: a bundle-id lookup misses instances launched directly from the binary (self-tests).
// Newest instance, so a self-test run is targeted rather than a copy the user has open.
guard let app = NSWorkspace.shared.runningApplications.filter({ $0.executableURL?.lastPathComponent == "LocalMusic" })
    .max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else {
    FileHandle.standardError.write(Data("LocalMusic is not running\n".utf8))
    exit(2)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 2)

func attribute<T>(_ element: AXUIElement, _ name: String, as: T.Type = T.self) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

/// Exact label match, or (second pass) a combined label that starts with it, e.g. an album tile "THE BOOK、YOASOBI".
func find(_ element: AXUIElement, prefix: Bool, depth: Int = 0) -> AXUIElement? {
    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attribute(element, $0, as: String.self) }
    if labels.contains(where: { prefix ? $0.hasPrefix(needle) : $0 == needle }) { return element }
    guard depth < 40 else { return nil }
    for child in attribute(element, kAXChildrenAttribute, as: [AXUIElement].self) ?? [] {
        if let hit = find(child, prefix: prefix, depth: depth + 1) { return hit }
    }
    return nil
}

guard var target = find(root, prefix: false) ?? find(root, prefix: true) else {
    FileHandle.standardError.write(Data("element not found: \(needle)\n".utf8))
    exit(1)
}
for _ in 0..<5 {
    if attribute(target, kAXRoleAttribute, as: String.self) == kAXRowRole {
        let result = AXUIElementSetAttributeValue(target, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        print("select row \(needle): \(result.rawValue)")
        exit(result == .success ? 0 : 1)
    }
    var actions: CFArray?
    if AXUIElementCopyActionNames(target, &actions) == .success, (actions as? [String])?.contains(kAXPressAction) == true {
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        print("press \(needle): \(result.rawValue)")
        exit(result == .success ? 0 : 1)
    }
    guard let parent: AXUIElement = attribute(target, kAXParentAttribute) else { break }
    target = parent
}
FileHandle.standardError.write(Data("no accessible action for \(needle)\n".utf8))
exit(1)
