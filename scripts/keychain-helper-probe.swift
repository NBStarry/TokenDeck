import Foundation
import Security

let arguments = CommandLine.arguments
let helper = URL(fileURLWithPath: arguments[1])
let account = arguments[2]
let mode = arguments[3]
func request(_ operation: String, service: String = "app.tokenusagedashboard.api", data: Data? = nil) throws -> [String: Any] {
    #if PACKAGED_BRIDGE
    let query: [String: Any] = [kSecAttrService as String: service, kSecAttrAccount as String: account]
    let (status, result) = KeychainBridge.perform(operation, query: query, data: data)
    var response: [String: Any] = ["status": Int(status)]
    if let result { response["data"] = result.base64EncodedString() }
    return response
    #else
    var value: [String: Any] = ["operation": operation, "service": service,
                               "account": account, "interactive": false]
    if let data { value["data"] = data.base64EncodedString() }
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = helper
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: value))
    try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return try JSONSerialization.jsonObject(with: result) as! [String: Any]
    #endif
}
let expected = Data("synthetic-test-value".utf8)
switch mode {
case "create":
    let absent = try request("read")
    precondition(absent["status"] as? Int == -25300)
    let write = try request("write", data: expected)
    precondition(write["status"] as? Int == 0)
case "verify":
    let read = try request("read")
    precondition(read["status"] as? Int == 0)
    precondition(read["data"] as? String == expected.base64EncodedString())
    let denied = try request("read", service: "unrelated-service")
    precondition(denied["status"] as? Int == -50)
    let claudeWrite = try request("write", service: "Claude Code-credentials", data: expected)
    precondition(claudeWrite["status"] as? Int == -50)
    let rotated = try request("write", data: expected)
    precondition(rotated["status"] as? Int == 0)
case "delete":
    let result = try request("delete")
    precondition([0, -25300].contains(result["status"] as? Int ?? 1))
case "untrusted":
    let result = try request("read")
    precondition(result["status"] as? Int == Int(errSecCSReqFailed))
default: fatalError("Unknown test mode")
}
#if SECOND_VERSION
print("PASS version 2", mode)
#else
print("PASS version 1", mode)
#endif
