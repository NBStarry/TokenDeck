import Foundation
import Security

// The helper and app deliberately share a designated requirement. Validate the
// live parent before accepting requests; never expose this as a general CLI.
func trustedParent() -> Bool {
    var own: SecCode?
    var ownStatic: SecStaticCode?
    var requirement: SecRequirement?
    var parent: SecCode?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
          SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
          SecCodeCopyDesignatedRequirement(ownStatic, [], &requirement) == errSecSuccess,
          let requirement,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: getppid()] as CFDictionary,
                                        [], &parent) == errSecSuccess, let parent else { return false }
    return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
}

func reply(_ status: OSStatus, _ data: Data? = nil) {
    var value: [String: Any] = ["status": Int(status)]
    if let data { value["data"] = data.base64EncodedString() }
    if let encoded = try? JSONSerialization.data(withJSONObject: value) {
        FileHandle.standardOutput.write(encoded)
    }
}

func run() {
    guard trustedParent() else { reply(errSecCSReqFailed); return }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 65536,
          let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          let service = request["service"] as? String,
          let operation = request["operation"] as? String,
          ["read", "write", "delete"].contains(operation) else { reply(errSecParam); return }
    let owned = ["app.tokenusagedashboard.codex", "app.tokenusagedashboard.api"].contains(service)
    guard owned || (service == "Claude Code-credentials" && operation == "read"),
          !owned || (request["account"] as? String)?.isEmpty == false else { reply(errSecParam); return }
    SecKeychainSetUserInteractionAllowed(request["interactive"] as? Bool == true)
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
    if let account = request["account"] as? String { query[kSecAttrAccount as String] = account }
    switch operation {
    case "read":
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        reply(status, result as? Data)
    case "write":
        guard let raw = request["data"] as? String, let data = Data(base64Encoded: raw) else {
            reply(errSecParam); return
        }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        reply(status)
    case "delete": reply(SecItemDelete(query as CFDictionary))
    default: reply(errSecParam)
    }
}
run()
