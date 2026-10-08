import Foundation
import Security

enum KeychainBridge {
    static var isPackaged: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func perform(_ operation: String, query: [String: Any], data: Data? = nil,
                        interactive: Bool = false) -> (OSStatus, Data?) {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TokenDeckKeychain")
        guard trustedHelper(helper) else { return (errSecCSReqFailed, nil) }
        var request: [String: Any] = ["operation": operation, "interactive": interactive]
        request["service"] = query[kSecAttrService as String]
        request["account"] = query[kSecAttrAccount as String]
        if let data { request["data"] = data.base64EncodedString() }
        guard let encoded = try? JSONSerialization.data(withJSONObject: request), encoded.count <= 65536 else {
            return (errSecParam, nil)
        }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: encoded)
            try input.fileHandleForWriting.close()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
                  let status = object["status"] as? Int32 else { return (errSecInternalComponent, nil) }
            return (status, (object["data"] as? String).flatMap { Data(base64Encoded: $0) })
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            return (errSecInternalComponent, nil)
        }
    }

    private static func trustedHelper(_ url: URL) -> Bool {
        var own: SecCode?
        var ownStatic: SecStaticCode?
        var requirement: SecRequirement?
        var helper: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopyDesignatedRequirement(ownStatic, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &helper) == errSecSuccess,
              let helper else { return false }
        return SecStaticCodeCheckValidity(helper, [], requirement) == errSecSuccess
    }
}
