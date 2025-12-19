import Foundation

extension BinaryDownloader {
    static func downloadMozillaCACert() async throws {
        let (data, _) = try await session.data(from: try url(from: "https://curl.se/ca/cacert.pem"))
        let finalPath = "\(getResourcesPath())/cacert-mozilla.pem"
        try data.write(to: URL(fileURLWithPath: finalPath))
    }
}
