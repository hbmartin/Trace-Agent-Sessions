import CryptoKit
import Darwin
import Foundation

public enum TraceFileIO {
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

public struct JSONLineRecord: Sendable {
    public let offset: Int64
    public let data: Data
}

public enum JSONLineReader {
    public static func forEachCompleteLine(
        at url: URL,
        from startOffset: Int64,
        body: (JSONLineRecord) throws -> Void
    ) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, startOffset)))

        var buffer = Data()
        var bufferOffset = max(0, startOffset)
        var committedOffset = bufferOffset

        while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let count = buffer.distance(from: buffer.startIndex, to: newline)
                var line = Data(buffer.prefix(count))
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty {
                    try body(.init(offset: bufferOffset, data: line))
                }
                let consumed = count + 1
                buffer.removeFirst(consumed)
                bufferOffset += Int64(consumed)
                committedOffset = bufferOffset
            }
        }

        return committedOffset
    }
}

public enum JSONDocumentScanner {
    /// Returns byte ranges for object values in the first JSON array associated
    /// with `arrayKey`. The scanner handles escaped strings and nested values.
    public static func objectRanges(in data: Data, arrayKey: String) -> [Range<Int>] {
        let bytes = [UInt8](data)
        guard let arrayStart = findArrayStart(bytes: bytes, key: arrayKey) else { return [] }

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

    private static func findArrayStart(bytes: [UInt8], key: String) -> Int? {
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
