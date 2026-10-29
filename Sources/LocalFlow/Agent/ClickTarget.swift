import ApplicationServices
import Foundation

/// Names the control under a point on screen ("Send", "Place order") from the
/// accessibility tree, so a click on something that can't be undone asks first. What
/// apps report is untrusted text: it's only matched against risky words and shown as
/// plain text on the approval card.
enum ClickTarget {
    static let maxLength = 60
    /// How far up from the element under the point to look for a name.
    static let maxDepth = 3
    /// The longest an app gets to answer, so a frozen one can't hold up LocalFlow.
    static let timeout: Float = 0.5

    /// What's under a point.
    enum Found: Equatable, Sendable {
        case named(String)
        case unnamed
        /// One of LocalFlow's own windows, which the agent can't see in its screenshots.
        case localFlow

        var name: String? {
            if case .named(let name) = self { return name }
            return nil
        }
    }

    struct ElementInfo: Equatable {
        var role: String?
        var title: String?
        var description: String?
        var value: String?
    }

    /// Roles whose value is what the user typed or picked, never a control's name.
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
                                                     "AXSecureTextField", "AXSlider", "AXScrollBar"]

    /// The first name found from the element up through its parents, stopping at the
    /// window (whose title is the document, not the control).
    static func label(for chain: [ElementInfo]) -> String? {
        for info in chain.prefix(maxDepth) {
            if info.role == "AXWindow" { return nil }
            let value = editableRoles.contains(info.role ?? "") ? nil : info.value
            for candidate in [info.title, info.description, value] {
                if let name = clean(candidate) { return name }
            }
        }
        return nil
    }

    /// What's at this global point (top-left origin). Call it off the main thread: when
    /// the point is on a LocalFlow window, LocalFlow's main thread has to answer.
    static func find(at point: CGPoint) -> Found {
        let system = AXUIElementCreateSystemWide()
        // Set on the system-wide element, this is the limit for every element asked.
        AXUIElementSetMessagingTimeout(system, timeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return .unnamed }
        var owner: pid_t = 0
        if AXUIElementGetPid(element, &owner) == .success, owner == getpid() { return .localFlow }
        var chain: [ElementInfo] = []
        var current: AXUIElement? = element
        while let node = current, chain.count < maxDepth {
            chain.append(ElementInfo(role: string(node, kAXRoleAttribute), title: string(node, kAXTitleAttribute),
                                     description: string(node, kAXDescriptionAttribute),
                                     value: string(node, kAXValueAttribute)))
            current = parent(of: node)
        }
        return label(for: chain).map(Found.named) ?? .unnamed
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let squeezed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !squeezed.isEmpty else { return nil }
        return squeezed.count > maxLength ? String(squeezed.prefix(maxLength - 1)) + "…" : squeezed
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
