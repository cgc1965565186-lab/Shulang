import Foundation
import Darwin

// MARK: - 目录条目元数据

public struct NodeMetadata: Sendable {
    public let url: URL
    public let name: String
    public let kind: NodeKind
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let modificationDate: Date?
    public let accessDate: Date?
    public let identity: FileIdentity?
    public let linkCount: Int
    public let isHidden: Bool
    public let isPackage: Bool
    public let isReadable: Bool
    public let changeDate: Date?

    public init(url: URL, name: String, kind: NodeKind, logicalSize: Int64,
                allocatedSize: Int64, modificationDate: Date?, accessDate: Date?,
                identity: FileIdentity?, linkCount: Int, isHidden: Bool,
                isPackage: Bool, isReadable: Bool, changeDate: Date? = nil) {
        self.url = url; self.name = name; self.kind = kind
        self.logicalSize = logicalSize; self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate; self.accessDate = accessDate
        self.identity = identity; self.linkCount = linkCount
        self.isHidden = isHidden; self.isPackage = isPackage; self.isReadable = isReadable
        self.changeDate = changeDate
    }
}

public struct DirectoryListing: Sendable {
    public let entries: [NodeMetadata]
    public let enumeratedCount: Int
    public let usedFallback: Bool
}

public enum EnumeratorKind: String, Codable, Sendable, CaseIterable {
    case foundation, bulk
    public var title: String {
        switch self { case .foundation: return "Foundation 枚举器"; case .bulk: return "getattrlistbulk 批量枚举器" }
    }
}

/// 目录枚举器协议。`nil` 表示该文件系统不支持，调用方应透明回落到 Foundation。
public protocol DirectoryEnumerating: Sendable {
    var kind: EnumeratorKind { get }
    func entries(at url: URL, includeHidden: Bool, shouldContinue: () -> Bool) throws -> DirectoryListing?
}

// MARK: - Foundation 基线枚举器（默认）

public struct FoundationEnumerator: DirectoryEnumerating {
    public let kind: EnumeratorKind = .foundation
    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileSizeKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey, .contentAccessDateKey,
        .linkCountKey, .isHiddenKey, .isReadableKey, .volumeIsReadOnlyKey
    ]

    public init() {}

    public func entries(at url: URL, includeHidden: Bool,
                        shouldContinue: () -> Bool) throws -> DirectoryListing? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Self.keys,
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else { return nil }

        var result: [NodeMetadata] = []
        var count = 0
        while let item = enumerator.nextObject() as? URL {
            if count % 64 == 0, !shouldContinue() { throw CancellationError() }
            count += 1
            let child = item.standardizedFileURL
            let values = try? child.resourceValues(forKeys: Set(Self.keys))
            let name = child.lastPathComponent
            guard !name.isEmpty, name != "." && name != ".." else { continue }
            let hidden = values?.isHidden ?? name.hasPrefix(".")
            if !includeHidden && hidden { continue }

            let isLink = values?.isSymbolicLink ?? false
            let isDir = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            let kind: NodeKind = isLink ? .symbolicLink : (isDir ? .directory : .file)
            let logical = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
            let allocated = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)

            var identity: FileIdentity?
            var linkCount = Int(values?.linkCount ?? 1)
            var readable = values?.isReadable ?? true
            var changeDate: Date?
            if let path = child.withUnsafeFileSystemRepresentation({ $0.map { String(cString: $0) } }) {
                var st = stat()
                if lstat(path, &st) == 0 {
                    identity = FileIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: UInt64(st.st_ino))
                    linkCount = Int(st.st_nlink)
                    readable = access(path, R_OK) == 0
                    changeDate = Date(timeIntervalSince1970: Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1_000_000_000)
                }
            }

            result.append(NodeMetadata(
                url: child, name: name, kind: kind,
                logicalSize: max(0, logical), allocatedSize: max(0, allocated),
                modificationDate: values?.contentModificationDate,
                accessDate: values?.contentAccessDate,
                identity: identity, linkCount: max(1, linkCount),
                isHidden: hidden, isPackage: isPackage, isReadable: readable, changeDate: changeDate
            ))
        }
        return DirectoryListing(entries: result, enumeratedCount: count, usedFallback: false)
    }
}

// MARK: - getattrlistbulk 批量枚举器（M1-10）

/// 一次系统调用取回整批目录项与元数据，避免每文件一次 stat。
/// 64 KiB 线程私有缓冲、严格边界校验；遇到不支持的文件系统、缺字段或任何异常即返回 nil，
/// 由调用方透明回落到 FoundationEnumerator。
public struct BulkEnumerator: DirectoryEnumerating {
    public let kind: EnumeratorKind = .bulk
    private static let bufferCapacity = 64 * 1024

    // Darwin 常量导入为 Int32，先按 Int32 逐项求或再转成 attrgroup_t(UInt32)，
    // 避免长表达式的类型推断超时，也让位图可读。
    private static let commonAttrs: attrgroup_t = {
        var bits: UInt32 = 0
        bits = bits | UInt32(ATTR_CMN_RETURNED_ATTRS)
        bits = bits | UInt32(ATTR_CMN_ERROR)
        bits = bits | UInt32(ATTR_CMN_NAME)
        bits = bits | UInt32(ATTR_CMN_DEVID)
        bits = bits | UInt32(ATTR_CMN_OBJTYPE)
        bits = bits | UInt32(ATTR_CMN_MODTIME)
        bits = bits | UInt32(ATTR_CMN_CHGTIME)
        bits = bits | UInt32(ATTR_CMN_FLAGS)
        bits = bits | UInt32(ATTR_CMN_USERACCESS)
        bits = bits | UInt32(ATTR_CMN_FILEID)
        return attrgroup_t(bits)
    }()
    private static let fileAttrs: attrgroup_t = {
        var bits: UInt32 = 0
        bits = bits | UInt32(ATTR_FILE_LINKCOUNT)
        bits = bits | UInt32(ATTR_FILE_TOTALSIZE)
        bits = bits | UInt32(ATTR_FILE_ALLOCSIZE)
        return attrgroup_t(bits)
    }()
    private static let unsupportedErrors: Set<Int32> = [EINVAL, ENOTSUP, ENOSYS]

    // sys/vnode.h: VREG = 1, VDIR = 2, VLNK = 5
    private static let vreg: UInt32 = 1
    private static let vdir: UInt32 = 2
    private static let vlnk: UInt32 = 5

    public init() {}

    public func entries(at url: URL, includeHidden: Bool,
                        shouldContinue: () -> Bool) throws -> DirectoryListing? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = Self.commonAttrs
        attributes.fileattr = Self.fileAttrs

        let path = url.path
        let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else {
            if Self.unsupportedErrors.contains(errno) { return nil }
            throw SLPOSIXError(code: errno, path: path)
        }
        defer { _ = Darwin.close(fd) }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferCapacity, alignment: 8)
        defer { buffer.deallocate() }

        var all: [NodeMetadata] = []
        var enumerated = 0
        var invalidated = false

        loop: while true {
            if !shouldContinue() { throw CancellationError() }
            let rawCount = getattrlistbulk(
                fd, &attributes, buffer, Self.bufferCapacity,
                UInt64(FSOPT_PACK_INVAL_ATTRS)
            )
            if rawCount < 0 {
                let e = errno
                if Self.unsupportedErrors.contains(e) { return nil }
                throw SLPOSIXError(code: e, path: path)
            }
            let count = Int(rawCount)
            if count == 0 { break }

            var cursor = 0
            for _ in 0..<count {
                if enumerated % 64 == 0, !shouldContinue() { throw CancellationError() }
                enumerated += 1
                guard let entry = Self.parseEntry(
                    buffer: buffer, start: cursor, capacity: Self.bufferCapacity,
                    parent: url, includeHidden: includeHidden
                ) else {
                    // 任何解析异常都放弃批量路径，改用 Foundation，绝不猜测元数据。
                    invalidated = true
                    break loop
                }
                cursor += entry.length
                if let metadata = entry.metadata { all.append(metadata) }
            }
        }
        if invalidated { return nil }
        return DirectoryListing(entries: all, enumeratedCount: enumerated, usedFallback: false)
    }

    private struct ParsedEntry {
        let length: Int
        let metadata: NodeMetadata?   // nil = 隐藏项 / 被排除项
    }

    /// 按 getattrlist(2) 声明顺序解析固定布局，所有读取均做边界检查。
    private static func parseEntry(buffer: UnsafeMutableRawPointer, start: Int,
                                   capacity: Int, parent: URL,
                                   includeHidden: Bool) -> ParsedEntry? {
        let base = UnsafeRawPointer(buffer)
        var c = ByteCursor(base: base, position: start, end: min(start + 64 * 1024, capacity))

        guard let entryLength: UInt32 = c.read() else { return nil }
        let length = Int(entryLength)
        guard length >= 8, start + length <= capacity else { return nil }
        c.end = start + length

        guard let returned: attribute_set_t = c.read(),
              let entryError: UInt32 = c.read() else { return nil }
        // 缺字段时不能用 packed 的默认值冒充真实元数据。
        guard returned.commonattr & commonAttrs == commonAttrs else { return nil }
        guard entryError == 0 else {
            return ParsedEntry(length: length, metadata: nil)
        }

        let nameRefOffset = c.position
        guard let nameRef: attrreference_t = c.read() else { return nil }
        let nameStart = nameRefOffset + Int(nameRef.attr_dataoffset)
        let nameLength = Int(nameRef.attr_length)
        guard nameStart >= start, nameStart + nameLength <= start + length, nameLength > 0 else { return nil }

        let nameBytes = UnsafeRawPointer(base.advanced(by: nameStart))
            .bindMemory(to: UInt8.self, capacity: nameLength)
        let effectiveLength = nameBytes[nameLength - 1] == 0 ? nameLength - 1 : nameLength
        guard effectiveLength > 0 else { return nil }
        let raw = UnsafeBufferPointer(start: nameBytes, count: effectiveLength)
        guard let name = String(bytes: raw, encoding: .utf8),
              !name.isEmpty, name != "." && name != "..",
              !name.contains("/"), !raw.contains(0) else { return nil }

        guard let devid: dev_t = c.read(),
              let objType: fsobj_type_t = c.read(),
              let modTime: timespec = c.read(),
              let changeTime: timespec = c.read(),
              let flags: UInt32 = c.read(),
              let userAccess: UInt32 = c.read(),
              let fileID: UInt64 = c.read() else { return nil }

        var linkCount: UInt32 = 1
        var logical: off_t = 0
        var allocated: off_t = 0
        if objType == vreg {
            guard let lc: UInt32 = c.read(), let ls: off_t = c.read(), let als: off_t = c.read() else { return nil }
            linkCount = lc; logical = ls; allocated = als
        }

        let hidden = name.hasPrefix(".") || (flags & UInt32(UF_HIDDEN)) != 0
        if !includeHidden && hidden { return ParsedEntry(length: length, metadata: nil) }

        let kind: NodeKind = objType == vlnk ? .symbolicLink
            : (objType == vdir ? .directory : .file)
        let childURL = parent.appending(path: name, directoryHint: objType == vdir ? .isDirectory : .notDirectory)
        let modDate = Date(timeIntervalSince1970: Double(modTime.tv_sec) + Double(modTime.tv_nsec) / 1_000_000_000)
        let changeDate = Date(timeIntervalSince1970: Double(changeTime.tv_sec) + Double(changeTime.tv_nsec) / 1_000_000_000)

        let metadata = NodeMetadata(
            url: childURL, name: name, kind: kind,
            logicalSize: max(0, Int64(logical)), allocatedSize: max(0, Int64(allocated)),
            modificationDate: modDate, accessDate: nil,
            identity: FileIdentity(device: UInt64(UInt32(bitPattern: devid)), inode: fileID),
            linkCount: max(1, Int(linkCount)), isHidden: hidden,
            isPackage: false, isReadable: (userAccess & UInt32(R_OK)) != 0, changeDate: changeDate
        )
        return ParsedEntry(length: length, metadata: metadata)
    }
}

private struct ByteCursor {
    let base: UnsafeRawPointer
    var position: Int
    var end: Int
    mutating func read<T>(_ type: T.Type = T.self) -> T? {
        let size = MemoryLayout<T>.size
        let aligned = (size + 3) & ~3
        guard position >= 0, position + aligned <= end else { return nil }
        let value = base.loadUnaligned(fromByteOffset: position, as: T.self)
        position += aligned
        return value
    }
}

public struct SLPOSIXError: Error, CustomStringConvertible {
    public let code: Int32
    public let path: String
    public var description: String { "\(String(cString: strerror(code))) (\(code)) @ \(path)" }
}

// MARK: - 卷信息

public enum VolumeProvider {
    public static func currentVolumes() -> [VolumeInfo] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey,
            .volumeIsLocalKey, .volumeURLKey
        ]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return [info(for: URL(fileURLWithPath: NSHomeDirectory()))]
        }
        var seen: Set<String> = []
        var result: [VolumeInfo] = []
        for url in urls {
            let key = url.resolvingSymlinksInPath().path
            guard seen.insert(key).inserted else { continue }
            result.append(info(for: url))
        }
        // 避免重复 APFS 根：/ 与 /System/Volumes/Data 只保留一个主展示项。
        return result.sorted { !$0.isExternal && $1.isExternal }
    }

    public static func info(for url: URL) -> VolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey, .volumeIsLocalKey
        ]
        let v = try? url.resourceValues(forKeys: keys)
        let isLocal = v?.volumeIsLocal ?? true
        return VolumeInfo(
            url: url, name: v?.volumeName ?? url.lastPathComponent,
            totalBytes: Int64(v?.volumeTotalCapacity ?? 0),
            availableBytes: Int64(v?.volumeAvailableCapacity ?? 0),
            importantAvailableBytes: v?.volumeAvailableCapacityForImportantUsage ?? 0,
            isExternal: !isLocal,
            isReadOnly: v?.volumeIsReadOnly ?? false
        )
    }
}

public enum TimeMachineInspector {
    public enum InspectionError: LocalizedError {
        case commandFailed(String)
        public var errorDescription: String? {
            switch self { case .commandFailed(let message): return message }
        }
    }

    /// Read-only report. Snapshot names are not a measure of reclaimable space.
    public static func localSnapshots(volume: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volume.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw InspectionError.commandFailed(text.isEmpty ? "无法读取本地快照" : text)
        }
        return text.isEmpty ? "没有返回本地快照。" : text
    }
}

// MARK: - 格式化（确定性纯函数）

public enum ByteFormat {
    /// 使用 1024 进制，保留 1 位小数；输入恒为非负。
    public static func string(_ bytes: Int64) -> String {
        let b = max(0, bytes)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(b)
        var index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        if index == 0 { return "\(b) B" }
        return String(format: "%.1f %@", value, units[index])
    }
    public static func precise(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return (formatter.string(from: NSNumber(value: max(0, bytes))) ?? "0") + " B"
    }
}
