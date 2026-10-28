/// The tools as the agent sees them in tools/list. The host app's permission policy
/// keys on these names and on `irreversible`, so keep them stable.
enum ComputerToolSchemas {
    static let irreversibleNote =
        "Set true when this action sends, posts, submits, buys, deletes, or otherwise can't be undone."

    static let all: [JSONValue] = [
        tool("screenshot",
             "Take a screenshot of the screen; every other tool's coordinates are pixels in the latest screenshot.",
             properties: [:]),
        tool("click",
             "Click at a pixel in the screenshot, optionally with another button, a double or triple click, or held keys.",
             properties: [
                 "x": pixel("Pixels from the left edge of the screenshot."),
                 "y": pixel("Pixels from the top edge of the screenshot."),
                 "button": ["type": "string", "enum": ["left", "right", "middle"], "default": "left"],
                 "clicks": ["type": "integer", "enum": [1, 2, 3], "default": 1,
                            "description": "2 for a double click, 3 for a triple click."],
                 "modifiers": ["type": "array", "description": "Keys to hold down while clicking.",
                               "items": ["type": "string", "enum": ["cmd", "shift", "option", "control"]]],
                 "irreversible": irreversible,
             ],
             required: ["x", "y"]),
        tool("move",
             "Move the mouse pointer to a pixel in the screenshot without clicking, for example to show a hover menu.",
             properties: ["x": pixel("Pixels from the left edge."), "y": pixel("Pixels from the top edge.")],
             required: ["x", "y"]),
        tool("drag",
             "Press the left mouse button at one pixel in the screenshot, drag to another, and release.",
             properties: [
                 "from_x": pixel("Start, pixels from the left edge."),
                 "from_y": pixel("Start, pixels from the top edge."),
                 "to_x": pixel("End, pixels from the left edge."),
                 "to_y": pixel("End, pixels from the top edge."),
             ],
             required: ["from_x", "from_y", "to_x", "to_y"]),
        tool("type",
             "Type text into the focused field as if on the keyboard; each newline presses Return.",
             properties: [
                 "text": ["type": "string", "description": "The text to type."],
                 "irreversible": irreversible,
             ],
             required: ["text"]),
        tool("key",
             "Press one key or shortcut, like return, escape, tab, cmd+shift+t, ctrl+a or option+left.",
             properties: [
                 "keys": ["type": "string",
                          "description": "A key name or character, joined to cmd, shift, option or control with +."],
                 "irreversible": irreversible,
             ],
             required: ["keys"]),
        tool("scroll",
             "Scroll the content under a pixel in the screenshot by a number of mouse-wheel notches.",
             properties: [
                 "x": pixel("Pixels from the left edge."),
                 "y": pixel("Pixels from the top edge."),
                 "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                 "amount": ["type": "integer", "minimum": 1, "maximum": 20, "default": 3,
                            "description": "Wheel notches to scroll."],
             ],
             required: ["x", "y", "direction"]),
        tool("open_app",
             "Open an app, or bring it to the front if it's already running, by name or bundle id.",
             properties: [
                 "name": ["type": "string", "description": "An app name like Safari or a bundle id like com.apple.Safari."],
             ],
             required: ["name"]),
        tool("list_apps",
             "List the running apps with their bundle ids and say which one is frontmost.",
             properties: [:]),
        tool("wait",
             "Wait a few seconds for something on screen to finish, like a page loading.",
             properties: [
                 "seconds": ["type": "number", "minimum": 0, "maximum": 10, "description": "Up to 10 seconds."],
             ],
             required: ["seconds"]),
    ]

    private static let irreversible: JSONValue = ["type": "boolean", "description": .string(irreversibleNote)]

    private static func pixel(_ description: String) -> JSONValue {
        ["type": "integer", "minimum": 0, "description": .string(description)]
    }

    private static func tool(_ name: String, _ description: String,
                             properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ],
        ]
    }
}
