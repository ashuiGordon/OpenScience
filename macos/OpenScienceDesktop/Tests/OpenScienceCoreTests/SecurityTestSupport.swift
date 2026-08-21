#if canImport(XCTest)
    import Foundation

    func makeSecurityTestDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openscience-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func writeExecutable(_ body: String, to url: URL) throws {
        let content = "#!/bin/sh\nset -eu\n\(body)\n"
        try Data(content.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }
#endif
