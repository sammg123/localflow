import Foundation

/// The stages the panel shows while an Instant run gets ready.
enum InstantStage: Equatable, Sendable {
    case viewingScreen
    case locatingProject
    /// The project's name.
    case projectFound(String)
    case readingDesignProfile
    /// One line saying what changes, such as "Making the Save button round instead of square".
    case makingChange(String)
}

/// Everything an Instant run starts with.
struct InstantPlan: Equatable, Sendable {
    let request: String
    let screenshotPNGBase64: String?
    /// The project, its path checked and made real: the InstantGuard's root.
    let project: InstantProject
    let profile: InstantDesignProfile
    let change: String
    /// For the run's `appendPrompt`.
    let instructions: String
}

/// Why an Instant run stops before editing anything.
enum InstantStop: Equatable, Sendable {
    case tooBig(String)
    case notUI(String)
    /// It couldn't tell which project, so LocalFlow asks.
    case needsProject(String)
    case unavailable(String)

    static let turnOff = "Turn off Instant (⌘I) to run it as a normal agent task."
    static let whichProject = "Which project is this? Tell me its folder or name and I'll remember it."
    static let noScreen = "LocalFlow couldn't see the screen. Check that it has Screen Recording permission, then try again."

    static func projectNotFound(_ name: String) -> String {
        "I couldn't find the folder for \(InstantSweepPrompt.oneLine(name)). Tell me its folder and I'll remember it."
    }

    /// What the panel tells the user.
    var message: String {
        switch self {
        case .tooBig(let reason), .notUI(let reason):
            return reason.contains("Turn off Instant") ? reason : reason + " " + Self.turnOff
        case .needsProject(let message), .unavailable(let message):
            return message
        }
    }
}

enum InstantOutcome: Equatable, Sendable {
    case ready(InstantPlan)
    case stopped(InstantStop)
}

/// Gets an Instant run ready, stage by stage: sees the screen, has the sweep sort the
/// request and name the project, checks the project's folder, and reads its design
/// profile. Everything it uses is passed in, so it runs the same with fakes.
@MainActor
struct InstantPipeline {
    typealias Capture = @Sendable () async -> String?
    typealias ReadProfile = @Sendable (String) async -> InstantDesignProfile

    let capture: Capture
    let sweep: any InstantSweeping
    let readProfile: ReadProfile
    let home: String
    let memoryPaths: [String]

    init(capture: @escaping Capture, sweep: any InstantSweeping,
         readProfile: @escaping ReadProfile = { InstantDesignProfile.find(in: $0) },
         home: String = NSHomeDirectory(), memoryPaths: [String] = []) {
        self.capture = capture
        self.sweep = sweep
        self.readProfile = readProfile
        self.home = home
        self.memoryPaths = memoryPaths
    }

    /// `memory` is the text of LocalFlow's memory file; `recent` lines about recent runs.
    func run(request: String, memory: String, recent: [String],
             onStage: (InstantStage) -> Void) async -> InstantOutcome {
        onStage(.viewingScreen)
        guard let screenshot = await capture() else { return .stopped(.unavailable(InstantStop.noScreen)) }
        onStage(.locatingProject)
        let input = InstantSweepInput(request: request, screenshotPNGBase64: screenshot, memory: memory, recent: recent)
        let sorted = await sweep.check(input)
        switch sorted.verdict {
        case .tooBig(let reason): return .stopped(.tooBig(reason))
        case .notUI(let reason): return .stopped(.notUI(reason))
        case .unavailable(let reason): return .stopped(.unavailable(reason))
        case .small: break
        }
        guard let named = sorted.project else { return .stopped(.needsProject(InstantStop.whichProject)) }
        guard let root = InstantFolders.projectRoot(named.path, home: home) else {
            return .stopped(.needsProject(InstantStop.projectNotFound(named.name)))
        }
        let name = InstantSweepPrompt.oneLine(named.name)
        let project = InstantProject(name: name.isEmpty ? URL(fileURLWithPath: root).lastPathComponent : name, path: root)
        onStage(.projectFound(project.name))
        onStage(.readingDesignProfile)
        let profile = await readProfile(root)
        onStage(.makingChange(sorted.change))
        let instructions = InstantPrompt.instructions(project: project, profile: profile, change: sorted.change,
                                                      memoryPaths: memoryPaths)
        return .ready(InstantPlan(request: request, screenshotPNGBase64: screenshot, project: project, profile: profile,
                                  change: sorted.change, instructions: instructions))
    }
}
