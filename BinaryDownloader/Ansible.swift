import Foundation
import Subprocess
import System

extension BinaryDownloader {
    static func downloadAnsible() async throws {
        // Python 3.14.0 from python-build-standalone
        let pythonURL = try url(from: "https://github.com/astral-sh/python-build-standalone/releases/download/20251028/cpython-3.14.0+20251028-aarch64-apple-darwin-install_only_stripped.tar.gz")
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
