import Foundation

/// Tools that publish, deploy or change things online. Package and deploy tools ask on
/// their risky subcommands; cloud tools ask unless they only list or describe.
enum AgentPublishing {
    static let label = "Publish or change things online"

    private static let containers: Set<String> = ["push", "rm", "rmi", "prune", "kill"]
    private static let packages: Set<String> = ["unpublish", "deprecate", "dist-tag", "owner", "access"]
    private static let infrastructure: Set<String> = ["apply", "destroy", "import", "taint", "state"]
    /// Subcommands that publish, deploy or delete, found anywhere among the plain words so
    /// an option in front can't hide one.
    private static let subcommands: [String: Set<String>] = [
        "docker": containers, "podman": containers, "cargo": ["publish", "yank", "owner"],
        "gem": ["push", "yank", "owner"], "twine": ["upload", "register"], "npm": packages, "pnpm": packages,
        "yarn": packages, "terraform": infrastructure, "tofu": infrastructure,
        "pulumi": ["up", "destroy", "import", "state", "cancel"], "helm": ["install", "upgrade", "uninstall", "delete", "rollback"],
        "netlify": ["deploy"], "wrangler": ["deploy", "publish", "delete", "secret", "rollback"],
        "railway": ["up", "deploy", "redeploy", "down", "delete"], "firebase": ["deploy"], "fly": ["deploy", "destroy"],
        "flyctl": ["deploy", "destroy"], "cdk": ["deploy", "destroy"], "sam": ["deploy", "delete"],
        "serverless": ["deploy", "remove"], "sls": ["deploy", "remove"], "supabase": ["deploy", "push", "reset", "delete"],
    ]
    /// Cloud tools and where their verb is: the words that only read, and the options
    /// before the verb that take a value.
    private static let cloud: [String: (verb: Verb, valued: Set<String>)] = [
        "aws": (.second(reads: ["ls", "help", "wait"]), ["--region", "--profile", "--output", "--endpoint-url", "--query",
                                                        "--color", "--ca-bundle", "--cli-read-timeout",
                                                        "--cli-connect-timeout", "--cli-binary-format"]),
        "kubectl": (.first(reads: kubeReads), kubeValued), "oc": (.first(reads: kubeReads), kubeValued),
        "vercel": (.first(reads: ["ls", "list", "inspect", "logs", "whoami", "help", "login", "logout", "link", "pull",
                                  "dev", "build"]), ["--scope", "--token", "-t", "--cwd"]),
        "gcloud": (.any(reads: anyReads), []), "az": (.any(reads: anyReads), []), "doctl": (.any(reads: anyReads), []),
    ]
    private static let kubeReads: Set<String> = ["get", "describe", "logs", "top", "explain", "version", "api-resources",
                                                 "api-versions", "cluster-info", "events", "diff", "wait"]
    private static let kubeValued: Set<String> = ["-n", "--namespace", "--context", "--kubeconfig", "--cluster", "--user",
                                                  "-s", "--server", "-l", "--selector", "-o", "--output", "-c",
                                                  "--container", "-f", "--filename"]
    private static let anyReads: Set<String> = ["list", "describe", "show", "get", "info", "version", "help", "ls"]

    enum Verb {
        /// The first plain word (`kubectl get`).
        case first(reads: Set<String>)
        /// The second plain word, after the service (`aws s3 ls`); `describe…`, `list…` and `get…` read too.
        case second(reads: Set<String>)
        /// Any plain word (`gcloud compute instances list`).
        case any(reads: Set<String>)
    }

    /// The tools whose first plain word must be plain text, not something the shell fills in.
    static func hasSubcommands(_ command: String) -> Bool {
        subcommands[command] != nil || cloud[command] != nil
    }

    /// The grant key for a risky use (`docker push`, `aws`), or nil.
    static func risky(_ command: String, _ args: [String]) -> String? {
        if let risky = subcommands[command] {
            let plain = args.filter { !$0.hasPrefix("-") }
            return risky.sorted().first(where: plain.contains).map { "\(command) \($0)" }
        }
        guard let (verb, valued) = cloud[command] else { return nil }
        let plain = args.indices.filter { !args[$0].hasPrefix("-") && !($0 > 0 && valued.contains(args[$0 - 1])) }
            .map { args[$0] }
        return readsOnly(verb, plain) ? nil : command
    }

    private static func readsOnly(_ verb: Verb, _ plain: [String]) -> Bool {
        switch verb {
        case .first(let reads): return plain.first.map(reads.contains) ?? false
        case .second(let reads):
            guard plain.count > 1 else { return false }
            let operation = plain[1]
            return reads.contains(operation) || ["describe", "list", "get"].contains { operation.hasPrefix($0) }
        case .any(let reads): return plain.contains(where: reads.contains)
        }
    }
}
