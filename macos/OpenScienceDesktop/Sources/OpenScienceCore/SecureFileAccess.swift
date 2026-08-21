import Darwin
import Foundation

struct SecureFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct SecureFileMetadata: Equatable, Sendable {
    let identity: SecureFileIdentity
    let size: UInt64
}

enum SecureFileViolation: Error, Equatable {
    case missing
    case outsideRoot
    case symlink
    case notRegular
    case changed
    case tooLarge(limit: Int)
    case unreadable(Int32)
}

enum SecureFileAccess {
    static func canonicalDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw SecureFileViolation.outsideRoot }
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { throw SecureFileViolation.missing }
            throw SecureFileViolation.unreadable(errno)
        }
        guard status.st_mode & S_IFMT != S_IFLNK else { throw SecureFileViolation.symlink }
        guard status.st_mode & S_IFMT == S_IFDIR else { throw SecureFileViolation.notRegular }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func readRegularFile(
        _ url: URL,
        within root: URL,
        maximumBytes: Int
    ) throws -> (data: Data, identity: SecureFileIdentity) {
        guard maximumBytes >= 0 else { throw SecureFileViolation.tooLarge(limit: maximumBytes) }
        let canonicalRoot = try canonicalDirectory(root)
        guard url.isFileURL, url.path.hasPrefix("/") else { throw SecureFileViolation.outsideRoot }

        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            if errno == ENOENT { throw SecureFileViolation.missing }
            throw SecureFileViolation.unreadable(errno)
        }
        guard before.st_mode & S_IFMT != S_IFLNK else { throw SecureFileViolation.symlink }
        guard before.st_mode & S_IFMT == S_IFREG else { throw SecureFileViolation.notRegular }

        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard contains(canonicalURL, in: canonicalRoot) else { throw SecureFileViolation.outsideRoot }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw SecureFileViolation.symlink }
            if errno == ENOENT { throw SecureFileViolation.missing }
            throw SecureFileViolation.unreadable(errno)
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw SecureFileViolation.unreadable(errno) }
        guard opened.st_mode & S_IFMT == S_IFREG else { throw SecureFileViolation.notRegular }
        guard before.st_dev == opened.st_dev, before.st_ino == opened.st_ino else {
            throw SecureFileViolation.changed
        }
        guard opened.st_size >= 0, opened.st_size <= maximumBytes else {
            throw SecureFileViolation.tooLarge(limit: maximumBytes)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw SecureFileViolation.tooLarge(limit: maximumBytes) }
        return (
            data,
            SecureFileIdentity(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino))
        )
    }

    static func regularFileMetadata(
        _ url: URL,
        within root: URL,
        maximumBytes: Int
    ) throws -> SecureFileMetadata {
        let canonicalRoot = try canonicalDirectory(root)
        guard url.isFileURL, url.path.hasPrefix("/") else { throw SecureFileViolation.outsideRoot }
        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            if errno == ENOENT { throw SecureFileViolation.missing }
            throw SecureFileViolation.unreadable(errno)
        }
        guard before.st_mode & S_IFMT != S_IFLNK else { throw SecureFileViolation.symlink }
        guard before.st_mode & S_IFMT == S_IFREG else { throw SecureFileViolation.notRegular }
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard contains(canonicalURL, in: canonicalRoot) else { throw SecureFileViolation.outsideRoot }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SecureFileViolation.unreadable(errno) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
            opened.st_mode & S_IFMT == S_IFREG,
            opened.st_dev == before.st_dev,
            opened.st_ino == before.st_ino
        else {
            throw SecureFileViolation.changed
        }
        guard opened.st_size >= 0, opened.st_size <= maximumBytes else {
            throw SecureFileViolation.tooLarge(limit: maximumBytes)
        }
        return SecureFileMetadata(
            identity: SecureFileIdentity(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino)),
            size: UInt64(opened.st_size)
        )
    }
}
