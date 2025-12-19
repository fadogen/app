import Testing
import Foundation
@testable import Fadogen

@MainActor
struct ProjectGeneratorValidationTests {
    let service = ProjectGeneratorService()
    let tempDir = FileManager.default.temporaryDirectory

    // MARK: - Project Name Validation

    @Test func validatesProjectName() {
        var config = ProjectConfiguration()
        config.projectName = "!!!" // No alphanumeric chars → nil after sanitization
        config.installDirectory = tempDir

        #expect(throws: ProjectGeneratorError.self) {
            try service.validate(config: config)
        }
    }

    @Test func acceptsValidProjectName() throws {
        var config = ProjectConfiguration()
        config.projectName = "my-laravel-app"
        config.installDirectory = tempDir

        try service.validate(config: config)
    }

    @Test func acceptsProjectNameWithNumbers() throws {
        var config = ProjectConfiguration()
        config.projectName = "my-app-2024"
        config.installDirectory = tempDir

        try service.validate(config: config)
    }

    // MARK: - Install Directory Validation

    @Test func validatesInstallDirectoryExists() {
        var config = ProjectConfiguration()
        config.projectName = "my-app"
        config.installDirectory = URL(fileURLWithPath: "/nonexistent/path")

        #expect(throws: ProjectGeneratorError.self) {
            try service.validate(config: config)
        }
    }

    @Test func validatesInstallDirectoryNotNil() {
        var config = ProjectConfiguration()
        config.projectName = "my-app"
        config.installDirectory = nil

        #expect(throws: ProjectGeneratorError.self) {
            try service.validate(config: config)
        }
    }

    // MARK: - Custom Starter Kit Validation

    @Test func validatesCustomRepoWhenCustomKit() {
        var config = ProjectConfiguration()
        config.projectName = "my-app"
        config.installDirectory = tempDir
        config.starterKit = .custom
        config.customStarterKitRepo = ""

        #expect(throws: ProjectGeneratorError.self) {
            try service.validate(config: config)
        }
    }

    @Test func acceptsValidComposerPackage() throws {
        var config = ProjectConfiguration()
        config.projectName = "my-app"
        config.installDirectory = tempDir
        config.starterKit = .custom
        config.customStarterKitRepo = "vendor/package"

        try service.validate(config: config)
    }

    @Test func acceptsGitURLAsCustomRepo() throws {
        var config = ProjectConfiguration()
        config.projectName = "my-app"
        config.installDirectory = tempDir
        config.starterKit = .custom
        config.customStarterKitRepo = "https://github.com/vendor/package.git"

        try service.validate(config: config)
    }

    @Test func acceptsSSHURLAsCustomRepo() throws {
        var config = ProjectConfiguration()
        config.projectName = "my-app"
        config.installDirectory = tempDir
        config.starterKit = .custom
        config.customStarterKitRepo = "git@github.com:vendor/package.git"

        try service.validate(config: config)
    }

    // MARK: - Normalization Integration

    @Test func ignoresVoltForNonLivewire() throws {
        var config = ProjectConfiguration()
        config.projectName = "my-app"
        config.installDirectory = tempDir
        config.starterKit = .react
        config.volt = true // Invalid but should be ignored

        // Should not throw because volt is ignored after normalization
        try service.validate(config: config)
    }

    // SSR is now a computed property based on starterKit, no test needed

    @Test func ignoresCustomRepoForNonCustomKit() throws {
        var config = ProjectConfiguration()
        config.projectName = "my-app"
        config.installDirectory = tempDir
        config.starterKit = .react
        config.customStarterKitRepo = "" // Would be invalid for .custom but ignored

        // Should not throw because customStarterKitRepo is ignored
        try service.validate(config: config)
    }
}
