import Foundation
import Subprocess
import System

/// Python version series to download (e.g., "3.14" will match 3.14.0, 3.14.1, etc.)
private let pythonMajorMinor = "3.14"

extension BinaryDownloader {
    static func downloadAnsible() async throws {
        // Step 1: Fetch latest release from python-build-standalone
        let apiURL = try url(from: "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest")
        let apiData = try await fetchGitHubAPI(url: apiURL)
        let release = try JSONDecoder().decode(PythonBuildStandaloneRelease.self, from: apiData)

        // Step 2: Find the asset matching our Python version and architecture
        let assetPrefix = "cpython-\(pythonMajorMinor)."
        let assetSuffix = "-aarch64-apple-darwin-install_only_stripped.tar.gz"

        guard let asset = release.assets.first(where: {
            $0.name.hasPrefix(assetPrefix) && $0.name.hasSuffix(assetSuffix)
        }) else {
            throw DownloadError.noMacOSAsset
        }

        // Step 3: Download Python from python-build-standalone (no checksum - GitHub releases are trusted)
        let pythonURL = try url(from: asset.browserDownloadUrl)
        let (tempURL, _) = try await session.download(from: pythonURL)

        // Extract to Resources/python/
        let destinationDir = "\(getResourcesPath())/python"
        try await extractArchive(
            from: tempURL,
            to: destinationDir,
            stripComponents: 1
        )

        // Install ansible (full package with 92 collections)
        let pipPath = "\(destinationDir)/bin/pip"
        let installAnsibleResult = try await Subprocess.run(
            .path(FilePath(pipPath)),
            arguments: .init(["install", "ansible", "--no-cache-dir", "--quiet"]),
            output: .discarded,
            error: .discarded
        )

        guard installAnsibleResult.terminationStatus.isSuccess else {
            throw DownloadError.extractionFailed
        }

        // Install geerlingguy roles one by one with retries (GitHub can return 503)
        let pythonPath = "\(destinationDir)/bin/python3"
        let rolesPath = "\(destinationDir)/ansible_roles"
        let roles = ["geerlingguy.pip", "geerlingguy.security", "geerlingguy.ntp", "geerlingguy.firewall", "geerlingguy.docker"]

        for role in roles {
            var success = false
            for attempt in 1...3 {
                let installRoleResult = try await Subprocess.run(
                    .path(FilePath(pythonPath)),
                    arguments: .init([
                        "-m", "ansible", "galaxy",
                        "role", "install",
                        role,
                        "--roles-path", rolesPath,
                        "--force"
                    ]),
                    workingDirectory: FilePath(destinationDir),
                    output: .discarded,
                    error: .discarded
                )

                if installRoleResult.terminationStatus.isSuccess {
                    success = true
                    break
                }

                if attempt < 3 {
                    try await Task.sleep(for: .seconds(2))
                }
            }

            guard success else {
                throw DownloadError.extractionFailed
            }
        }

        // Remove .pyc files to reduce size (~40% reduction)
        _ = try await Subprocess.run(
            .path("/usr/bin/find"),
            arguments: .init([destinationDir, "-name", "*.pyc", "-delete"]),
            output: .discarded,
            error: .discarded
        )
    }
}

// MARK: - Models

private struct PythonBuildStandaloneRelease: Codable {
    let tagName: String
    let assets: [PythonAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct PythonAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}
