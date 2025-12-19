import Testing
@testable import Fadogen

@MainActor
struct ProjectConfigurationNormalizationTests {

    // MARK: - Volt Tests

    @Test func clearsVoltWhenNotLivewire() {
        var config = ProjectConfiguration()
        config.starterKit = .livewire
        config.volt = true

        config.starterKit = .react
        let normalized = config.normalized()

        #expect(normalized.volt == false)
    }

    @Test func preservesVoltForLivewire() {
        var config = ProjectConfiguration()
        config.starterKit = .livewire
        config.authentication = .native
        config.volt = true

        let normalized = config.normalized()

        #expect(normalized.volt == true)
    }

    @Test func clearsVoltWhenWorkOSAuth() {
        var config = ProjectConfiguration()
        config.starterKit = .livewire
        config.authentication = .native
        config.volt = true

        // Switch to WorkOS - Volt should be cleared
        config.authentication = .workos
        let normalized = config.normalized()

        #expect(normalized.volt == false)
    }

    // MARK: - SSR Tests (SSR is computed, always true for React/Vue)

    @Test func ssrIsTrueForReact() {
        var config = ProjectConfiguration()
        config.starterKit = .react
        let normalized = config.normalized()
        #expect(normalized.ssr == true)
    }

    @Test func ssrIsTrueForVue() {
        var config = ProjectConfiguration()
        config.starterKit = .vue
        let normalized = config.normalized()
        #expect(normalized.ssr == true)
    }

    @Test func ssrIsFalseForLivewire() {
        var config = ProjectConfiguration()
        config.starterKit = .livewire
        let normalized = config.normalized()
        #expect(normalized.ssr == false)
    }

    // MARK: - Authentication Tests

    @Test func preservesAuthenticationWhenStillSupported() {
        var config = ProjectConfiguration()
        config.starterKit = .react
        config.authentication = .workos

        config.starterKit = .vue
        let normalized = config.normalized()

        #expect(normalized.authentication == .workos)
    }

    @Test func resetsAuthenticationWhenNotSupported() {
        var config = ProjectConfiguration()
        config.starterKit = .react
        config.authentication = .workos

        config.starterKit = .none
        let normalized = config.normalized()

        #expect(normalized.authentication == .native)
    }

    // MARK: - Custom Repo Tests

    @Test func clearsCustomRepoWhenNotCustomKit() {
        var config = ProjectConfiguration()
        config.starterKit = .custom
        config.customStarterKitRepo = "vendor/package"

        config.starterKit = .react
        let normalized = config.normalized()

        #expect(normalized.customStarterKitRepo.isEmpty)
    }

    @Test func preservesCustomRepoForCustomKit() {
        var config = ProjectConfiguration()
        config.starterKit = .custom
        config.customStarterKitRepo = "vendor/package"

        let normalized = config.normalized()

        #expect(normalized.customStarterKitRepo == "vendor/package")
    }

    // MARK: - Queue Backend Tests

    @Test func setsDefaultQueueBackendWhenQueueEnabled() {
        var config = ProjectConfiguration()
        config.queueService = .horizon
        config.queueBackend = nil

        let normalized = config.normalized()

        #expect(normalized.queueBackend == .valkey)
    }

    @Test func resetsQueueBackendWhenNotAvailable() {
        var config = ProjectConfiguration()
        config.queueService = .native
        config.queueBackend = .database

        config.queueService = .horizon
        let normalized = config.normalized()

        #expect(normalized.queueBackend == .valkey)
    }

    @Test func clearsQueueBackendWhenQueueDisabled() {
        var config = ProjectConfiguration()
        config.queueService = .horizon
        config.queueBackend = .redis

        config.queueService = .none
        let normalized = config.normalized()

        #expect(normalized.queueBackend == nil)
    }

    @Test func preservesValidQueueBackend() {
        var config = ProjectConfiguration()
        config.queueService = .horizon
        config.queueBackend = .redis

        let normalized = config.normalized()

        #expect(normalized.queueBackend == .redis)
    }

    // MARK: - Starter Kit Tests

    @Test func clearsStarterKitForSymfony() {
        var config = ProjectConfiguration()
        config.framework = .laravel
        config.starterKit = .react

        config.framework = .symfony
        let normalized = config.normalized()

        #expect(normalized.starterKit == .none)
    }

    // MARK: - Combination Tests

    @Test func allValidCombinationsNormalize() {
        for framework in Framework.allCases where framework.isAvailable {
            for starterKit in LaravelStarterKit.allCases {
                for queueService in QueueService.allCases {
                    var config = ProjectConfiguration()
                    config.framework = framework
                    config.starterKit = starterKit
                    config.queueService = queueService

                    let normalized = config.normalized()

                    // Verify coherence
                    if !normalized.showsVolt {
                        #expect(normalized.volt == false, "Volt should be false when not supported")
                    }
                    // SSR is now computed from starterKit.supportsSSR
                    #expect(normalized.ssr == normalized.starterKit.supportsSSR, "SSR should match starterKit.supportsSSR")
                    if normalized.showsQueueBackend {
                        #expect(normalized.queueBackend != nil, "Queue backend should be set when queue is enabled")
                        if let backend = normalized.queueBackend {
                            #expect(normalized.availableQueueBackends.contains(backend), "Queue backend should be in available list")
                        }
                    }
                }
            }
        }
    }
}
