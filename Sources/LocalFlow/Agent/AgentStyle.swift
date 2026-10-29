import SwiftUI

/// The agent's colors. Green marks it apart from Ask's blue and dictation's red.
enum AgentStyle {
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35) // #30d158
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.04)  // #ff9f0a
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)    // #ff453a
    /// Instant Edits.
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.04) // #ffd60a
    static let primary = AnswerView.primary
    static let secondary = AnswerView.secondary
}
