import Testing
@testable import Fadogen

@MainActor
struct ProjectConfigurationVisibilityTests {

    @Test func showsStarterKitForLaravel() {
        var config = ProjectConfiguration()
        config.framework = .laravel
        #expect(config.showsStarterKit == true)
    }

    @Test func hidesStarterKitForSymfony() {
        var config = ProjectConfiguration()
        config.framework = .symfony
        #expect(config.showsStarterKit == false)
    }

    @Test func showsVoltOnlyForLivewireWithNativeAuth() {
        var config = ProjectConfiguration()

        // Livewire with native auth shows Volt
        config.starterKit = .livewire
        config.authentication = .native
        #expect(config.showsVolt == true)

        // Livewire with WorkOS hides Volt
        config.authentication = .workos
        #expect(config.showsVolt == false)

        // Other starter kits never show Volt
        config.authentication = .native
        config.starterKit = .react
        #expect(config.showsVolt == false)

        config.starterKit = .vue
        #expect(config.showsVolt == false)

        config.starterKit = .none
        #expect(config.showsVolt == false)
    }

    @Test func ssrIsMandatoryForReactAndVue() {
        var config = ProjectConfiguration()

        config.starterKit = .react
        #expect(config.ssr == true)

        config.starterKit = .vue
        #expect(config.ssr == true)

        config.starterKit = .livewire
        #expect(config.ssr == false)

        config.starterKit = .none
        #expect(config.ssr == false)

        config.starterKit = .custom
        #expect(config.ssr == false)
    }

    @Test func showsAuthenticationForStarterKits() {
        var config = ProjectConfiguration()

        config.starterKit = .react
        #expect(config.showsAuthentication == true)

        config.starterKit = .vue
        #expect(config.showsAuthentication == true)

        config.starterKit = .livewire
        #expect(config.showsAuthentication == true)

        config.starterKit = .none
        #expect(config.showsAuthentication == false)

        config.starterKit = .custom
        #expect(config.showsAuthentication == false)
    }

    @Test func showsCustomRepoOnlyForCustomKit() {
        var config = ProjectConfiguration()

        config.starterKit = .custom
        #expect(config.showsCustomRepo == true)

        config.starterKit = .react
        #expect(config.showsCustomRepo == false)
    }

    @Test func showsQueueBackendWhenQueueEnabled() {
        var config = ProjectConfiguration()

        config.queueService = .none
        #expect(config.showsQueueBackend == false)

        config.queueService = .horizon
        #expect(config.showsQueueBackend == true)

        config.queueService = .native
        #expect(config.showsQueueBackend == true)
    }

    @Test func availableQueueBackendsForHorizon() {
        var config = ProjectConfiguration()
        config.queueService = .horizon
        #expect(config.availableQueueBackends == [.valkey, .redis])
    }

    @Test func availableQueueBackendsForNative() {
        var config = ProjectConfiguration()
        config.queueService = .native
        #expect(config.availableQueueBackends == [.valkey, .redis, .database])
    }

    @Test func availableQueueBackendsEmptyForNone() {
        var config = ProjectConfiguration()
        config.queueService = .none
        #expect(config.availableQueueBackends.isEmpty)
    }
}
