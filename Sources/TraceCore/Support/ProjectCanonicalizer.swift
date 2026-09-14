import Foundation

public enum ProjectCanonicalizer {
    public static func canonicalProject(for workingDirectory: String) -> (key: String, path: String, name: String) {
        let expanded = NSString(string: workingDirectory).expandingTildeInPath
        let start = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default

        var candidate = start
        while candidate.path != "/" {
            let gitEntry = candidate.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return result(for: candidate)
                }
                if let commonRoot = worktreeCommonRoot(gitFile: gitEntry) {
                    return result(for: commonRoot)
                }
                return result(for: candidate)
            }
            candidate.deleteLastPathComponent()
        }

        return result(for: start)
    }

    private static func worktreeCommonRoot(gitFile: URL) -> URL? {
        guard let contents = try? String(contentsOf: gitFile, encoding: .utf8),
              contents.hasPrefix("gitdir:")
        else { return nil }

        let rawGitDir = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = URL(fileURLWithPath: rawGitDir, relativeTo: gitFile.deletingLastPathComponent())
            .standardizedFileURL
        let commonFile = gitDir.appendingPathComponent("commondir")
        guard let common = try? String(contentsOf: commonFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return gitFile.deletingLastPathComponent() }

        let commonDirectory = URL(fileURLWithPath: common, relativeTo: gitDir).standardizedFileURL
        guard commonDirectory.lastPathComponent == ".git" else { return gitFile.deletingLastPathComponent() }
        return commonDirectory.deletingLastPathComponent()
    }

    private static func result(for url: URL) -> (key: String, path: String, name: String) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = canonical.path
        let name = canonical.lastPathComponent.isEmpty ? path : canonical.lastPathComponent
        return (path.folding(options: [.caseInsensitive], locale: .current), path, name)
    }
}
