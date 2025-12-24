import Foundation
import Testing
@testable import Fadogen

@MainActor
struct ViteConfigEditorTests {
    // MARK: - Test Fixtures

    /// Sample Laravel React starter kit vite.config.ts
    let reactStarterConfig = """
        import tailwindcss from '@tailwindcss/vite';
        import react from '@vitejs/plugin-react';
        import laravel from 'laravel-vite-plugin';
        import { defineConfig } from 'vite';

        export default defineConfig({
            plugins: [
                laravel({
                    input: 'resources/js/app.tsx',
                    ssr: 'resources/js/ssr.tsx',
                    refresh: true,
                }),
                react(),
                tailwindcss(),
            ],
        });
        """

    /// Sample Laravel Vue starter kit vite.config.ts
    let vueStarterConfig = """
        import tailwindcss from '@tailwindcss/vite';
        import vue from '@vitejs/plugin-vue';
        import laravel from 'laravel-vite-plugin';
        import { defineConfig } from 'vite';

        export default defineConfig({
            plugins: [
                laravel({
                    input: 'resources/js/app.ts',
                    ssr: 'resources/js/ssr.ts',
                    refresh: true,
                }),
                vue({
                    template: {
                        transformAssetUrls: {
                            base: null,
                            includeAbsolute: false,
                        },
                    },
                }),
                tailwindcss(),
            ],
        });
        """

    /// Sample minimal vite.config.js
    let minimalConfig = """
        import laravel from 'laravel-vite-plugin';
        import { defineConfig } from 'vite';

        export default defineConfig({
            plugins: [
                laravel({
                    input: ['resources/css/app.css', 'resources/js/app.js'],
                    refresh: true,
                }),
            ],
        });
        """

    /// Sample config with wayfinder plugin
    let wayfinderConfig = """
        import tailwindcss from '@tailwindcss/vite';
        import react from '@vitejs/plugin-react';
        import laravel from 'laravel-vite-plugin';
        import { defineConfig } from 'vite';
        import { wayfinder } from '@laravel/vite-plugin-wayfinder';

        export default defineConfig({
            plugins: [
                laravel({
                    input: 'resources/js/app.tsx',
                    ssr: 'resources/js/ssr.tsx',
                    refresh: true,
                }),
                react(),
                tailwindcss(),
                wayfinder(),
            ],
            esbuild: {
                jsx: 'automatic',
            }
        });
        """

    /// Config that already has fadogen
    let configWithFadogen = """
        import fadogen from '@fadogen/vite-plugin';
        import laravel from 'laravel-vite-plugin';
        import { defineConfig } from 'vite';

        export default defineConfig({
            plugins: [
                fadogen(),
                laravel({
                    input: 'resources/js/app.js',
                    refresh: true,
                }),
            ],
        });
        """

    /// Config that already has SSR config
    let configWithSSRConfig = """
        import fadogen from '@fadogen/vite-plugin';
        import laravel from 'laravel-vite-plugin';
        import { defineConfig } from 'vite';

        export default defineConfig({
            plugins: [
                fadogen(),
                laravel({
                    input: 'resources/js/app.tsx',
                    ssr: 'resources/js/ssr.tsx',
                    refresh: true,
                }),
            ],
            ssr: {
                noExternal: true,
            },
        });
        """

    // MARK: - Import Tests

    @Test func addsFadogenImportAfterLastImport() {
        let result = ViteConfigEditor.addFadogenPlugin(in: reactStarterConfig)

        #expect(result.contains("import fadogen from '@fadogen/vite-plugin';"))
        // Should be after the last import (defineConfig from 'vite')
        let fadogenImportIndex = result.range(of: "import fadogen from '@fadogen/vite-plugin';")!.lowerBound
        let defineConfigIndex = result.range(of: "import { defineConfig } from 'vite';")!.lowerBound
        #expect(fadogenImportIndex > defineConfigIndex)
    }

    @Test func addsFadogenImportForVueConfig() {
        let result = ViteConfigEditor.addFadogenPlugin(in: vueStarterConfig)

        #expect(result.contains("import fadogen from '@fadogen/vite-plugin';"))
    }

    @Test func addsFadogenImportForMinimalConfig() {
        let result = ViteConfigEditor.addFadogenPlugin(in: minimalConfig)

        #expect(result.contains("import fadogen from '@fadogen/vite-plugin';"))
    }

    @Test func addsFadogenImportAfterWayfinder() {
        let result = ViteConfigEditor.addFadogenPlugin(in: wayfinderConfig)

        #expect(result.contains("import fadogen from '@fadogen/vite-plugin';"))
        // Should be after wayfinder import
        let fadogenImportIndex = result.range(of: "import fadogen from '@fadogen/vite-plugin';")!.lowerBound
        let wayfinderIndex = result.range(of: "import { wayfinder } from '@laravel/vite-plugin-wayfinder';")!.lowerBound
        #expect(fadogenImportIndex > wayfinderIndex)
    }

    // MARK: - Plugin Array Tests

    @Test func addsFadogenAsFirstPlugin() {
        let result = ViteConfigEditor.addFadogenPlugin(in: reactStarterConfig)

        #expect(result.contains("fadogen(),"))
        // fadogen() should appear before laravel(
        let fadogenIndex = result.range(of: "fadogen(),")!.lowerBound
        let laravelIndex = result.range(of: "laravel({")!.lowerBound
        #expect(fadogenIndex < laravelIndex)
    }

    @Test func addsFadogenAsFirstPluginForVue() {
        let result = ViteConfigEditor.addFadogenPlugin(in: vueStarterConfig)

        let fadogenIndex = result.range(of: "fadogen(),")!.lowerBound
        let laravelIndex = result.range(of: "laravel({")!.lowerBound
        #expect(fadogenIndex < laravelIndex)
    }

    @Test func addsFadogenAsFirstPluginForMinimal() {
        let result = ViteConfigEditor.addFadogenPlugin(in: minimalConfig)

        let fadogenIndex = result.range(of: "fadogen(),")!.lowerBound
        let laravelIndex = result.range(of: "laravel({")!.lowerBound
        #expect(fadogenIndex < laravelIndex)
    }

    // MARK: - Idempotency Tests

    @Test func doesNotDuplicateFadogenIfAlreadyPresent() {
        let result = ViteConfigEditor.addFadogenPlugin(in: configWithFadogen)

        // Should remain unchanged
        #expect(result == configWithFadogen)
    }

    @Test func applyingTwiceProducesSameResult() {
        let firstPass = ViteConfigEditor.addFadogenPlugin(in: reactStarterConfig)
        let secondPass = ViteConfigEditor.addFadogenPlugin(in: firstPass)

        #expect(firstPass == secondPass)
    }

    // MARK: - Preservation Tests

    @Test func preservesExistingPlugins() {
        let result = ViteConfigEditor.addFadogenPlugin(in: reactStarterConfig)

        #expect(result.contains("laravel({"))
        #expect(result.contains("react(),"))
        #expect(result.contains("tailwindcss(),"))
    }

    @Test func preservesEsbuildConfig() {
        let result = ViteConfigEditor.addFadogenPlugin(in: wayfinderConfig)

        #expect(result.contains("esbuild: {"))
        #expect(result.contains("jsx: 'automatic',"))
    }

    @Test func preservesWayfinderPlugin() {
        let result = ViteConfigEditor.addFadogenPlugin(in: wayfinderConfig)

        #expect(result.contains("wayfinder(),"))
    }

    @Test func preservesSSRConfig() {
        let result = ViteConfigEditor.addFadogenPlugin(in: reactStarterConfig)

        #expect(result.contains("ssr: 'resources/js/ssr.tsx',"))
    }

    // MARK: - Indentation Tests

    @Test func matchesExistingIndentation() {
        let result = ViteConfigEditor.addFadogenPlugin(in: reactStarterConfig)

        // The fadogen() line should have the same indentation as laravel({
        let lines = result.components(separatedBy: .newlines)
        let fadogenLine = lines.first { $0.contains("fadogen(),") }
        let laravelLine = lines.first { $0.contains("laravel({") }

        #expect(fadogenLine != nil)
        #expect(laravelLine != nil)

        let fadogenIndent = fadogenLine!.prefix(while: { $0.isWhitespace })
        let laravelIndent = laravelLine!.prefix(while: { $0.isWhitespace })

        #expect(fadogenIndent == laravelIndent)
    }

    // MARK: - SSR Config Tests

    @Test func addsSSRConfigAfterPlugins() {
        let result = ViteConfigEditor.addSSRConfig(in: reactStarterConfig)

        #expect(result.contains("ssr: {"))
        #expect(result.contains("noExternal: true,"))
    }

    @Test func addsSSRConfigForVueConfig() {
        let result = ViteConfigEditor.addSSRConfig(in: vueStarterConfig)

        #expect(result.contains("ssr: {"))
        #expect(result.contains("noExternal: true,"))
    }

    @Test func addsSSRConfigForMinimalConfig() {
        let result = ViteConfigEditor.addSSRConfig(in: minimalConfig)

        #expect(result.contains("ssr: {"))
        #expect(result.contains("noExternal: true,"))
    }

    @Test func addsSSRConfigWithNestedBrackets() {
        // This tests that the bracket tracking works with nested arrays like input: [...]
        let result = ViteConfigEditor.addSSRConfig(in: minimalConfig)

        #expect(result.contains("ssr: {"))
        #expect(result.contains("noExternal: true,"))
        // Ensure the original nested array is preserved
        #expect(result.contains("input: ['resources/css/app.css', 'resources/js/app.js']"))
    }

    @Test func doesNotDuplicateSSRConfigIfAlreadyPresent() {
        let result = ViteConfigEditor.addSSRConfig(in: configWithSSRConfig)

        // Should remain unchanged
        #expect(result == configWithSSRConfig)
    }

    @Test func ssrConfigIdempotency() {
        let firstPass = ViteConfigEditor.addSSRConfig(in: reactStarterConfig)
        let secondPass = ViteConfigEditor.addSSRConfig(in: firstPass)

        #expect(firstPass == secondPass)
    }

    @Test func ssrConfigPreservesExistingPlugins() {
        let result = ViteConfigEditor.addSSRConfig(in: reactStarterConfig)

        #expect(result.contains("laravel({"))
        #expect(result.contains("react(),"))
        #expect(result.contains("tailwindcss(),"))
    }

    @Test func ssrConfigPreservesEsbuildConfig() {
        let result = ViteConfigEditor.addSSRConfig(in: wayfinderConfig)

        #expect(result.contains("esbuild: {"))
        #expect(result.contains("jsx: 'automatic',"))
    }

    @Test func ssrConfigDoesNotConfuseWithLaravelSSROption() {
        // The laravel plugin has its own "ssr:" option, ensure we don't confuse it
        // with the top-level ssr config
        let result = ViteConfigEditor.addSSRConfig(in: reactStarterConfig)

        // Should add ssr: { noExternal: true } even though laravel has ssr: 'resources/js/ssr.tsx'
        #expect(result.contains("ssr: {"))
        #expect(result.contains("noExternal: true,"))
        // Original laravel ssr option should be preserved
        #expect(result.contains("ssr: 'resources/js/ssr.tsx',"))
    }
}
