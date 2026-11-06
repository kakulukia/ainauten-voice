import XCTest
@testable import VoiceWisprCore

final class UpdatePolicyTests: XCTestCase {
    func testDevelopmentVersionUsesFourCommitCharactersAndBuildDate() {
        var info: [String: Any] = ["AInautenDistributionMode": "development",
            "AInautenBuildCommit": "078010debe66bf5285a6a13358370c530611f19f", "AInautenBuildDate": "2026-11-06",
            "CFBundleShortVersionString": "0.1.20", "CFBundleVersion": "27"]
        XCTAssertEqual(UpdatePolicy.displayVersion(info), "dev 0780 · 2026-11-06")
        info["AInautenBuildDirty"] = true
        XCTAssertEqual(UpdatePolicy.displayVersion(info), "dev 0780+ · 2026-11-06")
        info.removeValue(forKey: "AInautenDistributionMode"); info["AInautenLocalBuild"] = true
        XCTAssertEqual(UpdatePolicy.displayVersion(info), "dev 0780+ · 2026-11-06")
    }
    func testDevelopmentWithoutSourceMetadataDoesNotShowAnOldReleaseVersion() {
        XCTAssertEqual(UpdatePolicy.displayVersion(["AInautenDistributionMode": "development",
            "CFBundleShortVersionString": "0.1.14", "CFBundleVersion": "18"]), "dev ? · ?")
    }
    func testPublicVersionKeepsItsReleaseAndBuildNumbers() {
        XCTAssertEqual(UpdatePolicy.displayVersion(["AInautenDistributionMode": "apple-developer-id",
            "CFBundleShortVersionString": "0.1.20", "CFBundleVersion": "27",
            "AInautenBuildCommit": "078010d", "AInautenBuildDate": "2026-11-06"]), "0.1.20 (27)")
    }
    private var valid: [String: Any] { [
        "CFBundleIdentifier": "com.mediapublishing.VoiceWispr",
        "SUFeedURL": UpdatePolicy.feedURL,
        "SUPublicEDKey": Data(repeating: 42, count: 32).base64EncodedString(),
        "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true,
        "SUSignedFeedFailureExpirationInterval": 0
    ] }
    func testPublishingIdentityAndSignedChannelRequired() {
        XCTAssertTrue(UpdatePolicy.configured(valid))
        for field in ["SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUSignedFeedFailureExpirationInterval"] {
            var info = valid; info.removeValue(forKey: field)
            XCTAssertFalse(UpdatePolicy.configured(info), field)
        }
    }
    func testUntrustedFeedsAndMalformedKeysCannotStartUpdater() {
        for feed in ["http://voice.ainauten.com/updates/appcast.xml", "https://evil.example/appcast.xml", "https://voice.ainauten.com@evil.example/updates/appcast.xml", UpdatePolicy.feedURL + "?token=secret"] {
            var info = valid; info["SUFeedURL"] = feed; XCTAssertFalse(UpdatePolicy.configured(info))
        }
        for key in ["", "garbage", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 0, count: 32).base64EncodedString()] {
            var info = valid; info["SUPublicEDKey"] = key; XCTAssertFalse(UpdatePolicy.configured(info))
        }
    }
    func testFailClosedDoesNotExpireAndForeignBundleRejected() {
        var info = valid; info["SUSignedFeedFailureExpirationInterval"] = 1728000
        XCTAssertFalse(UpdatePolicy.configured(info))
        info = valid; info["CFBundleIdentifier"] = "com.other.App"; XCTAssertFalse(UpdatePolicy.configured(info))
    }
    func testRecordingProcessingOrSetupDefersUpdate() {
        XCTAssertFalse(UpdatePolicy.busy(recording: false, processing: false, setup: false))
        XCTAssertTrue(UpdatePolicy.busy(recording: true, processing: false, setup: false))
        XCTAssertTrue(UpdatePolicy.busy(recording: false, processing: true, setup: false))
        XCTAssertTrue(UpdatePolicy.busy(recording: false, processing: false, setup: true))
    }
}
