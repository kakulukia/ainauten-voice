import Foundation

/// A missing publishing identity must never turn into an unsigned updater.
public enum UpdatePolicy {
    public static let feedURL = "https://voice.ainauten.com/updates/appcast.xml"
    public static func displayVersion(_ info: [String: Any]) -> String {
        if info["AInautenDistributionMode"] as? String == "development" || info["AInautenLocalBuild"] as? Bool == true {
            let revision = info["AInautenBuildCommit"] as? String ?? "?"
            let date = info["AInautenBuildDate"] as? String ?? "?"
            let changed = info["AInautenBuildDirty"] as? Bool == true ? "+" : ""
            return "dev \(revision.prefix(4))\(changed) · \(date)"
        }
        return "\(info["CFBundleShortVersionString"] as? String ?? "0.1.1") (\(info["CFBundleVersion"] as? String ?? "3"))"
    }
    public static func configured(_ info: [String: Any]) -> Bool {
        guard info["CFBundleIdentifier"] as? String == "com.mediapublishing.VoiceWispr",
              info["SUFeedURL"] as? String == feedURL,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.contains(where: { $0 != 0 }),
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0 else { return false }
        return true
    }
    public static func busy(recording: Bool, processing: Bool, setup: Bool) -> Bool {
        recording || processing || setup
    }
}
