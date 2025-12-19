import Foundation
import Testing
@testable import Fadogen

@MainActor
struct ComposerJsonEditorTests {

    // MARK: - Test Fixtures

    /// Sample composer.json with both dev and dev:ssr scripts (React/Vue starter kit with Horizon)
    let composerWithHorizonAndSsr = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "post-autoload-dump": [
                    "Illuminate\\\\Foundation\\\\ComposerScripts::postAutoloadDump",
                    "@php artisan package:discover --ansi"
                ],
                "dev": [
                    "Composer\\\\Config::disableProcessTimeout",
                    "npx concurrently -c \\"#c4b5fd,#fdba74\\" \\"php artisan horizon\\" \\"npm run dev\\" --names=horizon,vite --kill-others"
                ],
                "dev:ssr": [
                    "npm run build:ssr",
                    "Composer\\\\Config::disableProcessTimeout",
                    "npx concurrently -c \\"#c4b5fd,#fdba74\\" \\"php artisan horizon\\" \\"php artisan inertia:start-ssr\\" --names=horizon,ssr --kill-others"
                ]
            }
        }
        """

    /// Sample composer.json with only dev script (Livewire starter kit - no SSR)
    let composerWithDevOnly = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "dev": [
                    "Composer\\\\Config::disableProcessTimeout",
                    "npx concurrently -c \\"#c4b5fd,#fdba74\\" \\"php artisan horizon\\" \\"npm run dev\\" --names=horizon,vite --kill-others"
                ]
            }
        }
        """

    /// Sample composer.json without dev scripts (plain Laravel without starter kit)
    let composerWithoutDevScripts = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "post-autoload-dump": [
                    "Illuminate\\\\Foundation\\\\ComposerScripts::postAutoloadDump",
                    "@php artisan package:discover --ansi"
                ]
            }
        }
        """

    /// Sample composer.json already using bun/bunx
    let composerWithBun = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "dev": [
                    "Composer\\\\Config::disableProcessTimeout",
                    "bunx concurrently -c \\"#c4b5fd,#fdba74\\" \\"php artisan horizon\\" \\"bun run dev\\" --names=horizon,vite --kill-others"
                ],
                "dev:ssr": [
                    "bun run build:ssr",
                    "Composer\\\\Config::disableProcessTimeout",
                    "bunx concurrently -c \\"#c4b5fd,#fdba74\\" \\"php artisan horizon\\" \\"php artisan inertia:start-ssr\\" --names=horizon,ssr --kill-others"
                ]
            }
        }
        """

    /// Sample composer.json with native queue (no Horizon)
    let composerWithNativeQueue = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "dev": [
                    "Composer\\\\Config::disableProcessTimeout",
                    "npx concurrently -c \\"#c4b5fd,#fdba74\\" \\"php artisan queue:work\\" \\"npm run dev\\" --names=queue,vite --kill-others"
                ]
            }
        }
        """

    /// Sample composer.json with setup script (deployment script)
    let composerWithSetup = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "setup": [
                    "composer install",
                    "@php -r \\"file_exists('.env') || copy('.env.example', '.env');\\"",
                    "@php artisan key:generate",
                    "@php artisan migrate --force",
                    "npm install",
                    "npm run build"
                ],
                "dev": [
                    "Composer\\\\Config::disableProcessTimeout",
                    "npx concurrently -c \\"#c4b5fd,#fdba74\\" \\"php artisan horizon\\" \\"npm run dev\\" --names=horizon,vite --kill-others"
                ]
            }
        }
        """

    /// Sample composer.json with setup script already using bun
    let composerWithSetupBun = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "setup": [
                    "composer install",
                    "@php -r \\"file_exists('.env') || copy('.env.example', '.env');\\"",
                    "@php artisan key:generate",
                    "@php artisan migrate --force",
                    "bun install",
                    "bun run build"
                ],
                "dev": [
                    "Composer\\\\Config::disableProcessTimeout",
                    "bunx concurrently -c \\"#c4b5fd,#fdba74\\" \\"php artisan horizon\\" \\"bun run dev\\" --names=horizon,vite --kill-others"
                ]
            }
        }
        """

    /// Sample composer.json with artisan serve (standard Laravel dev script)
    let composerWithArtisanServe = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "dev": [
                    "Composer\\\\Config::disableProcessTimeout",
                    "bunx concurrently -c \\"#93c5fd,#c4b5fd,#fb7185,#fdba74\\" \\"php artisan serve\\" \\"php artisan queue:listen --tries=1\\" \\"php artisan pail --timeout=0\\" \\"bun run dev\\" --names=server,queue,logs,vite --kill-others"
                ],
                "dev:ssr": [
                    "bun run build:ssr",
                    "Composer\\\\Config::disableProcessTimeout",
                    "bunx concurrently -c \\"#93c5fd,#c4b5fd,#fb7185,#fdba74\\" \\"php artisan serve\\" \\"php artisan queue:listen --tries=1\\" \\"php artisan pail --timeout=0\\" \\"php artisan inertia:start-ssr\\" --names=server,queue,logs,ssr --kill-others"
                ]
            }
        }
        """

    /// Sample composer.json without artisan serve (already removed)
    let composerWithoutArtisanServe = """
        {
            "name": "laravel/laravel",
            "type": "project",
            "scripts": {
                "dev": [
                    "Composer\\\\Config::disableProcessTimeout",
                    "bunx concurrently -c \\"#c4b5fd,#fb7185,#fdba74\\" \\"php artisan queue:listen --tries=1\\" \\"php artisan pail --timeout=0\\" \\"bun run dev\\" --names=queue,logs,vite --kill-others"
                ],
                "dev:ssr": [
                    "bun run build:ssr",
                    "Composer\\\\Config::disableProcessTimeout",
                    "bunx concurrently -c \\"#c4b5fd,#fb7185,#fdba74\\" \\"php artisan queue:listen --tries=1\\" \\"php artisan pail --timeout=0\\" \\"php artisan inertia:start-ssr\\" --names=queue,logs,ssr --kill-others"
                ]
            }
        }
        """

    // MARK: - Script Detection Tests

    @Test func detectsDevScript() {
        #expect(ComposerJsonEditor.hasDevScript(in: composerWithHorizonAndSsr))
        #expect(ComposerJsonEditor.hasDevScript(in: composerWithDevOnly))
        #expect(!ComposerJsonEditor.hasDevScript(in: composerWithoutDevScripts))
    }

    @Test func detectsDevSsrScript() {
        #expect(ComposerJsonEditor.hasDevSsrScript(in: composerWithHorizonAndSsr))
        #expect(!ComposerJsonEditor.hasDevSsrScript(in: composerWithDevOnly))
        #expect(!ComposerJsonEditor.hasDevSsrScript(in: composerWithoutDevScripts))
    }

    @Test func detectsSetupScript() {
        #expect(ComposerJsonEditor.hasSetupScript(in: composerWithSetup))
        #expect(!ComposerJsonEditor.hasSetupScript(in: composerWithHorizonAndSsr))
        #expect(!ComposerJsonEditor.hasSetupScript(in: composerWithoutDevScripts))
    }

    // MARK: - Replacement Tests

    @Test func replacesNpmWithBunInDevScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        #expect(result.contains("bun run dev"))
        #expect(!result.contains("npm run dev"))
    }

    @Test func replacesNpmWithBunInDevSsrScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        #expect(result.contains("bun run build:ssr"))
        #expect(!result.contains("npm run build:ssr"))
    }

    @Test func replacesOnlyInDevScriptWhenNoSsr() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithDevOnly)

        #expect(result.contains("bun run dev"))
        #expect(!result.contains("npm run dev"))
        // Should not contain any SSR references
        #expect(!result.contains("build:ssr"))
    }

    @Test func preservesOtherScripts() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        // post-autoload-dump should be unchanged
        #expect(result.contains("post-autoload-dump"))
        #expect(result.contains("@php artisan package:discover --ansi"))
    }

    @Test func preservesHorizonCommand() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        #expect(result.contains("php artisan horizon"))
    }

    @Test func preservesInertiaStartSsr() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        #expect(result.contains("php artisan inertia:start-ssr"))
    }

    @Test func replacesNpxWithBunxInDevScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        #expect(result.contains("bunx concurrently"))
        #expect(!result.contains("npx concurrently"))
    }

    @Test func replacesNpxWithBunxInDevSsrScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        // Both dev and dev:ssr should have bunx
        let devScriptRange = result.range(of: "\"dev\":")!
        let devSsrScriptRange = result.range(of: "\"dev:ssr\":")!

        // Check that bunx appears after dev:ssr (meaning it was replaced in that script too)
        let afterDevSsr = String(result[devSsrScriptRange.upperBound...])
        #expect(afterDevSsr.contains("bunx concurrently"))
    }

    @Test func replacesNpmInstallWithBunInstallInSetupScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithSetup)

        #expect(result.contains("bun install"))
        #expect(!result.contains("npm install"))
    }

    @Test func replacesNpmRunBuildWithBunRunBuildInSetupScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithSetup)

        #expect(result.contains("bun run build"))
        #expect(!result.contains("npm run build"))
    }

    @Test func preservesComposerInstallInSetupScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithSetup)

        #expect(result.contains("composer install"))
    }

    @Test func preservesArtisanCommandsInSetupScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithSetup)

        #expect(result.contains("@php artisan key:generate"))
        #expect(result.contains("@php artisan migrate --force"))
    }

    @Test func handlesNativeQueueScript() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithNativeQueue)

        #expect(result.contains("bun run dev"))
        #expect(result.contains("bunx concurrently"))
        #expect(result.contains("php artisan queue:work"))
        #expect(!result.contains("npx "))
    }

    // MARK: - Idempotency Tests

    @Test func doesNotModifyIfAlreadyUsingBun() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithBun)

        // Should remain unchanged
        #expect(result == composerWithBun)
    }

    @Test func applyingTwiceProducesSameResult() {
        let firstPass = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)
        let secondPass = ComposerJsonEditor.replaceNpmWithBun(in: firstPass)

        #expect(firstPass == secondPass)
    }

    @Test func doesNotModifySetupIfAlreadyUsingBun() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithSetupBun)

        // Should remain unchanged
        #expect(result == composerWithSetupBun)
    }

    @Test func applyingTwiceToSetupProducesSameResult() {
        let firstPass = ComposerJsonEditor.replaceNpmWithBun(in: composerWithSetup)
        let secondPass = ComposerJsonEditor.replaceNpmWithBun(in: firstPass)

        #expect(firstPass == secondPass)
    }

    // MARK: - Edge Cases

    @Test func handlesEmptyContent() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: "")

        #expect(result == "")
    }

    @Test func handlesNoScriptsSection() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithoutDevScripts)

        // Should remain unchanged
        #expect(result == composerWithoutDevScripts)
    }

    @Test func preservesJsonStructure() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        // Should still be valid JSON structure (basic check)
        #expect(result.contains("{"))
        #expect(result.contains("}"))
        #expect(result.contains("\"scripts\":"))
    }

    // MARK: - Both Scripts Modified Together

    @Test func modifiesBothDevAndDevSsrInSinglePass() {
        let result = ComposerJsonEditor.replaceNpmWithBun(in: composerWithHorizonAndSsr)

        // All npm/npx should be replaced in a single call
        #expect(result.contains("bun run dev"))
        #expect(result.contains("bun run build:ssr"))
        #expect(result.contains("bunx concurrently"))
        #expect(!result.contains("npm run dev"))
        #expect(!result.contains("npm run build:ssr"))
        #expect(!result.contains("npx "))
    }

    // MARK: - Remove Artisan Serve Tests

    @Test func removesArtisanServeFromDevScript() {
        let result = ComposerJsonEditor.removeArtisanServe(in: composerWithArtisanServe)

        #expect(!result.contains("php artisan serve"))
    }

    @Test func removesArtisanServeFromDevSsrScript() {
        let result = ComposerJsonEditor.removeArtisanServe(in: composerWithArtisanServe)

        // Check dev:ssr script specifically
        let devSsrRange = result.range(of: "\"dev:ssr\":")!
        let afterDevSsr = String(result[devSsrRange.upperBound...])
        #expect(!afterDevSsr.contains("php artisan serve"))
    }

    @Test func removesServerFromNames() {
        let result = ComposerJsonEditor.removeArtisanServe(in: composerWithArtisanServe)

        #expect(!result.contains("--names=server,"))
        #expect(result.contains("--names=queue,logs,vite"))
        #expect(result.contains("--names=queue,logs,ssr"))
    }

    @Test func removesServerColor() {
        let result = ComposerJsonEditor.removeArtisanServe(in: composerWithArtisanServe)

        #expect(!result.contains("#93c5fd,"))
        #expect(result.contains("#c4b5fd,#fb7185,#fdba74"))
    }

    @Test func preservesOtherArtisanCommands() {
        let result = ComposerJsonEditor.removeArtisanServe(in: composerWithArtisanServe)

        #expect(result.contains("php artisan queue:listen"))
        #expect(result.contains("php artisan pail"))
        #expect(result.contains("php artisan inertia:start-ssr"))
        #expect(result.contains("bun run dev"))
    }

    @Test func removeArtisanServeIsIdempotent() {
        let firstPass = ComposerJsonEditor.removeArtisanServe(in: composerWithArtisanServe)
        let secondPass = ComposerJsonEditor.removeArtisanServe(in: firstPass)

        #expect(firstPass == secondPass)
    }

    @Test func handlesAlreadyRemovedArtisanServe() {
        let result = ComposerJsonEditor.removeArtisanServe(in: composerWithoutArtisanServe)

        #expect(result == composerWithoutArtisanServe)
    }

    @Test func removeArtisanServePreservesHorizonScript() {
        // Horizon scripts don't have artisan serve, should remain unchanged
        let result = ComposerJsonEditor.removeArtisanServe(in: composerWithHorizonAndSsr)

        #expect(result.contains("php artisan horizon"))
    }
}
