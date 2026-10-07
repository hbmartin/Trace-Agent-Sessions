import CryptoKit
import Darwin
import Foundation
import os

public enum TraceFileIO {
    private struct VolumeCaseSensitivityCache {
        var values: [String: Bool] = [:]
        var probeCounts: [String: Int] = [:]
    }

    private static let volumeCaseSensitivity = OSAllocatedUnfairLock(
        initialState: VolumeCaseSensitivityCache()
    )

    public struct CanonicalPath: Hashable, Sendable {
        public let path: String
        public let comparisonKey: String
        let isCaseSensitive: Bool

        public func contains(_ other: CanonicalPath) -> Bool {
            if comparisonKey == other.comparisonKey { return true }
            let prefix = comparisonKey == "/" || comparisonKey.hasSuffix("/")
                ? comparisonKey
                : comparisonKey + "/"
            return other.comparisonKey.hasPrefix(prefix)
        }

        public func intersects(_ other: CanonicalPath) -> Bool {
            contains(other) || other.contains(self)
        }
    }

    public static func canonicalPath(_ rawPath: String) -> CanonicalPath {
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL
        var ancestor = standardized
        var missingComponents: [String] = []
        var status = stat()
        while stat(ancestor.path, &status) != 0 {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        let resolvedAncestor = ancestor.resolvingSymlinksInPath()
        var resolved = resolvedAncestor
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        resolved = resolved.standardizedFileURL
        let path = resolved.path
        let caseSensitive = volumeIsCaseSensitive(at: resolvedAncestor)
        return .init(
            path: path,
            comparisonKey: comparisonKey(path, caseSensitive: caseSensitive),
            isCaseSensitive: caseSensitive
        )
    }

    static func comparisonKey(_ path: String, caseSensitive: Bool) -> String {
        caseSensitive ? path : path.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func volumeIsCaseSensitive(at existingURL: URL) -> Bool {
        let values = try? existingURL.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .volumeSupportsCaseSensitiveNamesKey,
        ])
        return cachedVolumeCaseSensitivity(volumeID: values?.volumeUUIDString) {
            probeVolumeCaseSensitivity(
                at: existingURL,
                resourceValue: values?.volumeSupportsCaseSensitiveNames
            )
        }
    }

    static func cachedVolumeCaseSensitivity(
        volumeID: String?, probe: () -> Bool
    ) -> Bool {
        guard let volumeID else { return probe() }
        if let cached = volumeCaseSensitivity.withLock({ $0.values[volumeID] }) {
            return cached
        }
        let detected = probe()
        return volumeCaseSensitivity.withLock { cache in
            if let cached = cache.values[volumeID] { return cached }
            cache.values[volumeID] = detected
            cache.probeCounts[volumeID, default: 0] += 1
            return detected
        }
    }

    private static func probeVolumeCaseSensitivity(
        at existingURL: URL, resourceValue: Bool?
    ) -> Bool {
        probeVolumeCaseSensitivity(resourceValue: resourceValue) {
            pathconf(existingURL.path, _PC_CASE_SENSITIVE)
        }
    }

    static func probeVolumeCaseSensitivity(
        resourceValue: Bool?, pathConfiguration: () -> Int
    ) -> Bool {
        if let resourceValue { return resourceValue }
        let pathConfiguration = pathConfiguration()
        if pathConfiguration == 0 || pathConfiguration == 1 {
            return pathConfiguration == 1
        }
        // Avoid merging distinct paths when the volume cannot report its behavior.
        return true
    }

    static func resetVolumeCaseSensitivityCacheForTesting() {
        volumeCaseSensitivity.withLock { $0 = .init() }
    }

    static var volumeCaseSensitivityProbeCountForTesting: Int {
        volumeCaseSensitivity.withLock { cache in
            cache.probeCounts.values.reduce(0, +)
        }
    }

    public static func isCodexMetadataSidecar(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "session_index.jsonl" { return true }
        guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return false }
        let start = name.index(name.startIndex, offsetBy: "state_".count)
        let end = name.index(name.endIndex, offsetBy: -".sqlite".count)
        let generation = name[start..<end]
        return !generation.isEmpty && generation.allSatisfy(\.isNumber)
    }

    public static func isCodexMetadataChangePath(_ url: URL) -> Bool {
        if isCodexMetadataSidecar(url) { return true }
        let name = url.lastPathComponent
        guard name.hasSuffix(".sqlite-wal") else { return false }
        let database = url.deletingLastPathComponent().appendingPathComponent(
            String(name.dropLast("-wal".count))
        )
        return isCodexMetadataSidecar(database)
    }

    public static func modificationMilliseconds(url: URL) -> Int64 {
        if let fingerprint = try? fingerprint(url: url) {
            return fingerprint.modificationNanoseconds / 1_000_000
        }
        if let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
            return Int64(modified.timeIntervalSince1970 * 1_000)
        }
        return 0
    }

    public static func read(url: URL, offset: Int64, length: Int64) throws -> Data {
        guard length >= 0, length <= Int64(Int.max) else {
            throw SessionSourceError.unreadableFile(url.path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)) else { return Data() }
        return data
    }

    public static func fingerprint(url: URL, preferredHeadLength: Int? = nil) throws -> SourceFingerprint {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw SessionSourceError.unreadableFile(url.path)
        }

        let fileSize = Int64(status.st_size)
        let headLength = max(0, min(preferredHeadLength ?? 4_096, 4_096, Int(fileSize)))
        let head = try read(url: url, offset: 0, length: Int64(headLength))
        let digest = Data(SHA256.hash(data: head))
        let modificationNanoseconds = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(status.st_mtimespec.tv_nsec)

        return .init(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            size: fileSize,
            modificationNanoseconds: modificationNanoseconds,
            headHash: digest,
            headLength: headLength
        )
    }
}

/// Relates changes to a symlinked Codex sidecar's target back to the metadata
/// directory whose cached names were loaded through that sidecar.
public struct CodexMetadataSidecarMapping: Equatable, Sendable {
    private let sidecarsByDependency: [String: Set<String>]
    private let insensitiveDependencies: [String: Set<String>]
    private let insensitiveHomes: Set<String>
    public let targetDirectories: [URL]
    public let configuredSidecars: Set<String>
    public let linkPaths: Set<String>
    public let metadataDirectoryPaths: Set<String>
    public let diagnostics: [String]
    private let linkDestinations: [String: String]
    private let homeEntries: [String: Set<String>]
    let namespaceDirectories: [URL]
    private let entryIdentities: [String: EntryIdentity]

    private struct EntryIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let kind: UInt16
        init(_ path: String) {
            var value = stat()
            if lstat(path, &value) == 0 {
                kind = UInt16(value.st_mode & S_IFMT)
                // Regular-file replacement changes content, not watch topology.
                device = kind == S_IFREG ? 0 : UInt64(value.st_dev)
                inode = kind == S_IFREG ? 0 : UInt64(value.st_ino)
            } else { device = 0; inode = 0; kind = 0 }
        }
    }

    public init(metadataDirectories: [URL]) {
        var dependencies: [String: Set<String>] = [:]
        var insensitiveDependencies: [String: Set<String>] = [:]
        var directories: Set<String> = []
        var namespaceDirectories: Set<String> = []
        var identityPaths: Set<String> = []
        let userHome = TraceFileIO.canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path).path
        func addContentDirectory(_ path: String) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            let canonical = TraceFileIO.canonicalPath(path).path
            identityPaths.insert(canonical)
            if canonical == "/" || canonical == userHome { namespaceDirectories.insert(canonical) }
            else { directories.insert(canonical) }
        }
        var configured: Set<String> = []
        var links: Set<String> = []
        var homes: Set<String> = []
        var warnings: Set<String> = []
        let fm = FileManager.default
        func watchParent(of path: String) {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            while !fm.fileExists(atPath: parent.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                let next = parent.deletingLastPathComponent()
                if next == parent { break }
                parent = next
            }
            let physical = TraceFileIO.canonicalPath(parent.path).path
            namespaceDirectories.insert(physical)
            identityPaths.formUnion([path, parent.path, physical])
        }
        // Resolve one component at a time, recording ancestor and intermediate links.
        // Foundation's final resolution loses those dependencies and can loop on cycles.
        func resolve(_ path: String) -> (path: String, dependencies: Set<String>, links: Set<String>, complete: Bool) {
            var remaining = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.dropFirst().map { $0 }
            var current = URL(fileURLWithPath: "/")
            var seen: Set<String> = []
            var foundLinks: Set<String> = []
            var found: Set<String> = [path]
            var hops = 0
            while !remaining.isEmpty {
                let component = remaining.removeFirst()
                if component == "." { continue }
                if component == ".." { current.deleteLastPathComponent(); continue }
                current.appendPathComponent(component)
                found.insert(current.path)
                identityPaths.insert(current.path)
                watchParent(of: current.path)
                if let destination = try? fm.destinationOfSymbolicLink(atPath: current.path) {
                    found.insert(current.path)
                    hops += 1
                    foundLinks.insert(current.path)
                    let state = current.path + "|" + remaining.joined(separator: "/")
                    guard hops <= 40, seen.insert(state).inserted else {
                        return (current.path, found, foundLinks, false)
                    }
                    if destination.hasPrefix("/") { current = URL(fileURLWithPath: "/") }
                    else { current.deleteLastPathComponent() }
                    remaining = destination.split(separator: "/").map(String.init) + remaining
                }
            }
            found.insert(current.path)
            return (current.path, found, foundLinks, true)
        }
        for directory in metadataDirectories {
            let home = directory.standardizedFileURL.path
            watchParent(of: home)
            let resolvedHome = resolve(home)
            homes.formUnion([home, resolvedHome.path, TraceFileIO.canonicalPath(resolvedHome.path).path])
            for link in resolvedHome.links { links.insert(link); watchParent(of: link) }
            if !resolvedHome.complete {
                warnings.insert("\(home): incomplete Codex metadata monitoring (symlink cycle or more than 40 hops)")
                continue
            }
            var homeIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: resolvedHome.path, isDirectory: &homeIsDirectory), homeIsDirectory.boolValue {
                addContentDirectory(resolvedHome.path)
            } else {
                watchParent(of: URL(fileURLWithPath: resolvedHome.path).appendingPathComponent("session_index.jsonl").path)
            }
            let names = (try? fm.contentsOfDirectory(atPath: resolvedHome.path)) ?? []
            // Retain a missing index dependency so recovery/creation invalidates its cache.
            let candidates = Set(names.filter { TraceFileIO.isCodexMetadataSidecar(URL(fileURLWithPath: $0)) })
                .union(["session_index.jsonl"])
            for name in candidates {
                let configuredPath = directory.appendingPathComponent(name).standardizedFileURL.path
                configured.insert(configuredPath)
                let resolved = resolve(configuredPath)
                if resolved.complete {
                    addContentDirectory(URL(fileURLWithPath: resolved.path).deletingLastPathComponent().path)
                }
                links.formUnion(resolved.links)
                links.formUnion(resolved.links.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
                var paths = resolved.dependencies
                paths.insert(URL(fileURLWithPath: resolvedHome.path).appendingPathComponent(name).path)
                if name.hasSuffix(".sqlite") {
                    paths.insert(resolved.path + "-wal")
                    paths.insert(configuredPath + "-wal")
                }
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    let parent = TraceFileIO.canonicalPath(url.deletingLastPathComponent().path)
                    let physicalParent = parent.path
                    let parentNormalized = URL(fileURLWithPath: physicalParent).appendingPathComponent(url.lastPathComponent).path
                    dependencies[parentNormalized, default: []].insert(configuredPath)
                    let canonical = TraceFileIO.canonicalPath(path)
                    dependencies[canonical.path, default: []].insert(configuredPath)
                    if !parent.isCaseSensitive {
                        for variant in [path, parentNormalized] {
                            insensitiveDependencies[TraceFileIO.comparisonKey(variant, caseSensitive: false), default: []].insert(configuredPath)
                        }
                    }
                    if !canonical.isCaseSensitive {
                        insensitiveDependencies[canonical.comparisonKey, default: []].insert(configuredPath)
                    }
                    if resolved.links.contains(path) { links.insert(parentNormalized) }
                    dependencies[path, default: []].insert(configuredPath)
                    dependencies[URL(fileURLWithPath: path).standardizedFileURL.path, default: []].insert(configuredPath)
                    watchParent(of: path)
                }
                if !resolved.complete {
                    warnings.insert("\(configuredPath): incomplete Codex metadata monitoring (symlink cycle or more than 40 hops)")
                }
            }
        }
        sidecarsByDependency = dependencies
        self.insensitiveDependencies = insensitiveDependencies
        insensitiveHomes = Set(homes.compactMap { path in
            let canonical = TraceFileIO.canonicalPath(path)
            return canonical.isCaseSensitive ? nil : TraceFileIO.comparisonKey(path, caseSensitive: false)
        })
        targetDirectories = directories.sorted().map { URL(fileURLWithPath: $0) }
        configuredSidecars = configured
        linkPaths = links
        metadataDirectoryPaths = homes
        diagnostics = warnings.sorted()
        linkDestinations = Set(dependencies.keys).union(homes).union(identityPaths).reduce(into: [:]) { result, path in
            result[path] = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? ""
        }
        homeEntries = homes.reduce(into: [:]) { result, path in
            result[path] = Self.sidecarNames(at: path)
        }
        self.namespaceDirectories = namespaceDirectories.sorted().map { URL(fileURLWithPath: $0) }
        entryIdentities = identityPaths.union(homes).union(directories).reduce(into: [:]) { result, path in
            result[path] = EntryIdentity(path)
        }
    }

    public func configuredSidecarsWithChangedDependencies(comparedTo other: Self) -> Set<String> {
        var affected = configuredSidecars.symmetricDifference(other.configuredSidecars)
        for dependency in Set(sidecarsByDependency.keys).union(other.sidecarsByDependency.keys) {
            if sidecarsByDependency[dependency] != other.sidecarsByDependency[dependency]
                || linkDestinations[dependency] != other.linkDestinations[dependency]
                || entryIdentities[dependency] != other.entryIdentities[dependency] {
                affected.formUnion(sidecarsByDependency[dependency] ?? [])
                affected.formUnion(other.sidecarsByDependency[dependency] ?? [])
            }
        }
        return affected
    }

    private static func sidecarNames(at path: String) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter {
            TraceFileIO.isCodexMetadataSidecar(URL(fileURLWithPath: $0))
        })
    }

    /// Called only for a relevant dependency/structure event, on a utility queue.
    /// Content writes and atomic replacement of a regular file keep the mapping.
    public var topologyHasChanged: Bool {
        let fm = FileManager.default
        return linkDestinations.contains { path, destination in
            ((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "") != destination
        } || homeEntries.contains { Self.sidecarNames(at: $0.key) != $0.value }
            || entryIdentities.contains { EntryIdentity($0.key) != $0.value }
    }

    func monitorIdentityChanged(at path: String, comparedTo other: Self) -> Bool {
        entryIdentities[path] != other.entryIdentities[path]
    }

    /// No filesystem access: safe for filtering raw FSEvents before canonicalization.
    public func configuredRawChangePaths(for path: String) -> Set<String> {
        if let matched = sidecarsByDependency[path] { return matched }
        guard !insensitiveDependencies.isEmpty else { return [] }
        return insensitiveDependencies[TraceFileIO.comparisonKey(path, caseSensitive: false)] ?? []
    }

    public func configuredChangePaths(for path: String) -> Set<String> {
        let raw = URL(fileURLWithPath: path).standardizedFileURL.path
        let matched = configuredRawChangePaths(for: raw)
        if !matched.isEmpty { return matched }
        return configuredRawChangePaths(for: TraceFileIO.canonicalPath(raw).path)
    }

    public func configuredRecoveryPaths(for scope: String) -> Set<String> {
        let prefix = scope.hasSuffix("/") ? scope : scope + "/"
        var result = sidecarsByDependency.reduce(into: Set<String>()) { result, entry in
            if entry.key == scope || entry.key.hasPrefix(prefix) { result.formUnion(entry.value) }
        }
        let folded = TraceFileIO.comparisonKey(scope, caseSensitive: false)
        let foldedPrefix = folded.hasSuffix("/") ? folded : folded + "/"
        for entry in insensitiveDependencies where entry.key == folded || entry.key.hasPrefix(foldedPrefix) {
            result.formUnion(entry.value)
        }
        return result
    }

    public func isMetadataStructurePath(_ path: String) -> Bool {
        if linkPaths.contains(path) || metadataDirectoryPaths.contains(path) { return true }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let home = metadataDirectoryPaths.contains(parent)
            || insensitiveHomes.contains(TraceFileIO.comparisonKey(parent, caseSensitive: false))
        return home && TraceFileIO.isCodexMetadataSidecar(url)
    }
}

public struct JSONLineRecord: Sendable {
    public let offset: Int64
    public let data: Data
    public let endOffset: Int64
}

/// A finite, pull-driven reader. Appends beyond the captured boundary belong to the next pass.
final class JSONLineCursor {
    private let handle: FileHandle
    private let endOffset: Int64
    private var readOffset: Int64
    private var bufferOffset: Int64
    private var buffer = Data()
    private(set) var checkpoint: Int64

    init(url: URL, from offset: Int64, through boundary: Int64? = nil) throws {
        handle = try FileHandle(forReadingFrom: url)
        let size = Int64(try handle.seekToEnd())
        endOffset = min(size, boundary ?? size)
        readOffset = max(0, offset)
        bufferOffset = readOffset
        checkpoint = readOffset
        try handle.seek(toOffset: UInt64(readOffset))
    }

    deinit { try? handle.close() }

    func next() throws -> JSONLineRecord? {
        while true {
            try Task.checkCancellation()
            if let newline = buffer.firstIndex(of: 0x0A) {
                let count = buffer.distance(from: buffer.startIndex, to: newline)
                var line = Data(buffer.prefix(count))
                if line.last == 0x0D { line.removeLast() }
                let start = bufferOffset
                let consumed = count + 1
                buffer.removeFirst(consumed)
                bufferOffset += Int64(consumed)
                checkpoint = bufferOffset
                return .init(offset: start, data: line, endOffset: checkpoint)
            }
            guard readOffset < endOffset,
                  let chunk = try handle.read(upToCount: Int(min(256 * 1_024, endOffset - readOffset))),
                  !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            readOffset += Int64(chunk.count)
        }
    }
}

public enum JSONLineReader {
    public static func forEachCompleteLine(
        at url: URL,
        from startOffset: Int64,
        body: (JSONLineRecord) throws -> Void
    ) throws -> Int64 {
        let cursor = try JSONLineCursor(url: url, from: startOffset)
        while let line = try cursor.next() {
            if !line.data.isEmpty { try body(line) }
        }
        return cursor.checkpoint
    }
}

/// Each iterator is consumed serially. The parser and cursor are owned exclusively by that iterator.
private final class RecordStreamState: @unchecked Sendable {
    let url: URL
    let offset: Int64
    let boundary: Int64?
    let parse: (JSONLineRecord) throws -> [ParsedRecord]
    var cursor: JSONLineCursor?
    var pending: ArraySlice<ParsedRecord> = []

    init(url: URL, offset: Int64, boundary: Int64?, parse: @escaping (JSONLineRecord) throws -> [ParsedRecord]) {
        self.url = url
        self.offset = offset
        self.boundary = boundary
        self.parse = parse
    }

    func next() throws -> ParsedRecord? {
        try Task.checkCancellation()
        if let record = pending.popFirst() { return record }
        if cursor == nil { cursor = try JSONLineCursor(url: url, from: offset, through: boundary) }
        guard let line = try cursor?.next() else { return nil }
        let records = line.data.isEmpty ? [] : try parse(line)
        pending = ArraySlice(records + [.checkpoint(line.endOffset)])
        return pending.popFirst()
    }
}

enum ParsedRecordStream {
    static func jsonLines(
        url: URL, from offset: Int64, through boundary: Int64?,
        parse: @escaping (JSONLineRecord) throws -> [ParsedRecord]
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        let state = RecordStreamState(url: url, offset: offset, boundary: boundary, parse: parse)
        return AsyncThrowingStream(unfolding: { try state.next() })
    }
}

public enum JSONDocumentScanner {
    /// Returns byte ranges for object values in the first JSON array associated
    /// with `arrayKey`. The scanner handles escaped strings and nested values.
    public static func objectRanges(in data: Data, arrayKey: String) -> [Range<Int>] {
        let bytes = [UInt8](data)
        guard let arrayStart = arrayStart(bytes: bytes, key: arrayKey) else { return [] }

        var result: [Range<Int>] = []
        var index = arrayStart + 1
        var inString = false
        var escaped = false
        var objectDepth = 0
        var objectStart: Int?

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                if objectDepth == 0 { objectStart = index }
                objectDepth += 1
            } else if byte == 0x7D, objectDepth > 0 {
                objectDepth -= 1
                if objectDepth == 0, let start = objectStart {
                    result.append(start..<(index + 1))
                    objectStart = nil
                }
            } else if byte == 0x5D, objectDepth == 0 {
                break
            }
            index += 1
        }
        return result
    }

    static func arrayStart(in data: Data, arrayKey: String) -> Int? {
        arrayStart(bytes: [UInt8](data), key: arrayKey)
    }

    private static func arrayStart(bytes: [UInt8], key: String) -> Int? {
        guard let keyData = "\"\(key)\"".data(using: .utf8) else { return nil }
        let needle = [UInt8](keyData)
        guard bytes.count >= needle.count else { return nil }

        var inString = false
        var escaped = false
        var index = 0
        while index <= bytes.count - needle.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                if Array(bytes[index..<(index + needle.count)]) == needle {
                    var cursor = index + needle.count
                    while cursor < bytes.count, bytes[cursor].isJSONWhitespace { cursor += 1 }
                    if cursor < bytes.count, bytes[cursor] == 0x3A {
                        cursor += 1
                        while cursor < bytes.count, bytes[cursor].isJSONWhitespace { cursor += 1 }
                        if cursor < bytes.count, bytes[cursor] == 0x5B { return cursor }
                    }
                }
                inString = true
            }
            index += 1
        }
        return nil
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
