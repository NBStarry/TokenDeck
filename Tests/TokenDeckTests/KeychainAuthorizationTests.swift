import XCTest
import Security
@testable import TokenDeck

final class KeychainAuthorizationTests: XCTestCase {
    func testPartialFailureStillChecksEveryCredential() {
        var statuses: [OSStatus] = [errSecInteractionNotAllowed, errSecSuccess, errSecItemNotFound]
        let report = KeychainAuthorization.inspect(entries: [("A", [:]), ("B", [:]), ("C", [:])]) { _ in
            statuses.removeFirst()
        }
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(report.checked, 3)
        XCTAssertEqual(report.failures.count, 2)
        XCTAssertTrue(report.message.contains("始终允许"))
        XCTAssertTrue(report.message.contains("凭证不存在"))
        XCTAssertFalse(report.message.contains("授权完成"))
        XCTAssertFalse(report.message.contains("过期"))
    }

    func testSuccessRequiresEveryReadToSucceed() {
        let report = KeychainAuthorization.inspect(entries: [("A", [:]), ("B", [:])]) { _ in errSecSuccess }
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.message.contains("已验证后续无弹窗读取成功"))
    }

    func testEmptyConfigurationDoesNotClaimAuthorization() {
        let report = KeychainAuthorization.inspect(entries: []) { _ in XCTFail("Unexpected read"); return errSecSuccess }
        XCTAssertFalse(report.message.contains("授权完成"))
    }

    func testCanceledDeniedAndUnknownErrorsRemainActionable() {
        for status in [errSecUserCanceled, errSecAuthFailed, OSStatus(-12345)] {
            let report = KeychainAuthorization.inspect(entries: [("A", [:])]) { _ in status }
            XCTAssertEqual(report.failures.count, 1)
            XCTAssertTrue(report.message.contains(String(status)))
            XCTAssertFalse(report.message.contains("过期"))
        }
    }
    func testHelperTrustFailureDoesNotAskForAnotherPassword() {
        let report = KeychainAuthorization.inspect(entries: [("A", [:])]) { _ in errSecCSReqFailed }
        XCTAssertTrue(report.message.contains("签名校验失败"))
        XCTAssertFalse(report.message.contains("始终允许"))
    }

}
