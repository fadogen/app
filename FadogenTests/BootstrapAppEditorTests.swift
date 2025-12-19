import Foundation
import Testing
@testable import Fadogen

@MainActor
struct BootstrapAppEditorTests {
    // MARK: - Test Fixtures

    /// Sample Laravel React starter kit bootstrap/app.php
    let reactStarterBootstrap = """
        <?php

        use App\\Http\\Middleware\\HandleAppearance;
        use App\\Http\\Middleware\\HandleInertiaRequests;
        use Illuminate\\Foundation\\Application;
        use Illuminate\\Foundation\\Configuration\\Exceptions;
        use Illuminate\\Foundation\\Configuration\\Middleware;
        use Illuminate\\Http\\Middleware\\AddLinkHeadersForPreloadedAssets;

        return Application::configure(basePath: dirname(__DIR__))
            ->withRouting(
                web: __DIR__.'/../routes/web.php',
                commands: __DIR__.'/../routes/console.php',
                health: '/up',
            )
            ->withMiddleware(function (Middleware $middleware): void {
                $middleware->encryptCookies(except: ['appearance', 'sidebar_state']);

                $middleware->web(append: [
                    HandleAppearance::class,
                    HandleInertiaRequests::class,
                    AddLinkHeadersForPreloadedAssets::class,
                ]);
            })
            ->withExceptions(function (Exceptions $exceptions): void {
                //
            })->create();
        """

    /// Sample Laravel Vue starter kit bootstrap/app.php (identical structure)
    let vueStarterBootstrap = """
        <?php

        use App\\Http\\Middleware\\HandleAppearance;
        use App\\Http\\Middleware\\HandleInertiaRequests;
        use Illuminate\\Foundation\\Application;
        use Illuminate\\Foundation\\Configuration\\Exceptions;
        use Illuminate\\Foundation\\Configuration\\Middleware;
        use Illuminate\\Http\\Middleware\\AddLinkHeadersForPreloadedAssets;

        return Application::configure(basePath: dirname(__DIR__))
            ->withRouting(
                web: __DIR__.'/../routes/web.php',
                commands: __DIR__.'/../routes/console.php',
                health: '/up',
            )
            ->withMiddleware(function (Middleware $middleware): void {
                $middleware->encryptCookies(except: ['appearance', 'sidebar_state']);

                $middleware->web(append: [
                    HandleAppearance::class,
                    HandleInertiaRequests::class,
                    AddLinkHeadersForPreloadedAssets::class,
                ]);
            })
            ->withExceptions(function (Exceptions $exceptions): void {
                //
            })->create();
        """

    /// Minimal bootstrap/app.php (Laravel base without starter kit)
    let minimalBootstrap = """
        <?php

        use Illuminate\\Foundation\\Application;
        use Illuminate\\Foundation\\Configuration\\Exceptions;
        use Illuminate\\Foundation\\Configuration\\Middleware;

        return Application::configure(basePath: dirname(__DIR__))
            ->withRouting(
                web: __DIR__.'/../routes/web.php',
                commands: __DIR__.'/../routes/console.php',
                health: '/up',
            )
            ->withMiddleware(function (Middleware $middleware): void {
                //
            })
            ->withExceptions(function (Exceptions $exceptions): void {
                //
            })->create();
        """

    /// Bootstrap with Reverb broadcasting channels
    let bootstrapWithChannels = """
        <?php

        use App\\Http\\Middleware\\HandleAppearance;
        use App\\Http\\Middleware\\HandleInertiaRequests;
        use Illuminate\\Foundation\\Application;
        use Illuminate\\Foundation\\Configuration\\Exceptions;
        use Illuminate\\Foundation\\Configuration\\Middleware;
        use Illuminate\\Http\\Middleware\\AddLinkHeadersForPreloadedAssets;

        return Application::configure(basePath: dirname(__DIR__))
            ->withRouting(
                web: __DIR__.'/../routes/web.php',
                commands: __DIR__.'/../routes/console.php',
                channels: __DIR__.'/../routes/channels.php',
                health: '/up',
            )
            ->withMiddleware(function (Middleware $middleware): void {
                $middleware->encryptCookies(except: ['appearance', 'sidebar_state']);

                $middleware->web(append: [
                    HandleAppearance::class,
                    HandleInertiaRequests::class,
                    AddLinkHeadersForPreloadedAssets::class,
                ]);
            })
            ->withExceptions(function (Exceptions $exceptions): void {
                //
            })->create();
        """

    /// Bootstrap that already has trustProxies configured
    let bootstrapWithTrustProxies = """
        <?php

        use App\\Http\\Middleware\\HandleAppearance;
        use App\\Http\\Middleware\\HandleInertiaRequests;
        use Illuminate\\Foundation\\Application;
        use Illuminate\\Foundation\\Configuration\\Exceptions;
        use Illuminate\\Foundation\\Configuration\\Middleware;
        use Illuminate\\Http\\Middleware\\AddLinkHeadersForPreloadedAssets;

        return Application::configure(basePath: dirname(__DIR__))
            ->withRouting(
                web: __DIR__.'/../routes/web.php',
                commands: __DIR__.'/../routes/console.php',
                channels: __DIR__.'/../routes/channels.php',
                health: '/up',
            )
            ->withMiddleware(function (Middleware $middleware): void {
                $middleware->trustProxies(at: [
                    '10.0.0.0/8',
                    '172.16.0.0/12',
                    '192.168.0.0/16',
                ]);

                $middleware->encryptCookies(except: ['appearance', 'sidebar_state']);

                $middleware->web(append: [
                    HandleAppearance::class,
                    HandleInertiaRequests::class,
                    AddLinkHeadersForPreloadedAssets::class,
                ]);
            })
            ->withExceptions(function (Exceptions $exceptions): void {
                //
            })->create();
        """

    // MARK: - Insertion Tests

    @Test func addsTrustedProxiesToReactBootstrap() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        #expect(result.contains("trustProxies"))
        #expect(result.contains("10.0.0.0/8"))
        #expect(result.contains("172.16.0.0/12"))
        #expect(result.contains("192.168.0.0/16"))
    }

    @Test func addsTrustedProxiesToVueBootstrap() {
        let result = BootstrapAppEditor.addTrustedProxies(in: vueStarterBootstrap)

        #expect(result.contains("trustProxies"))
        #expect(result.contains("Docker Swarm overlay networks"))
    }

    @Test func addsTrustedProxiesToMinimalBootstrap() {
        let result = BootstrapAppEditor.addTrustedProxies(in: minimalBootstrap)

        #expect(result.contains("trustProxies"))
    }

    @Test func addsTrustedProxiesToBootstrapWithChannels() {
        let result = BootstrapAppEditor.addTrustedProxies(in: bootstrapWithChannels)

        #expect(result.contains("trustProxies"))
        // Channels should still be present
        #expect(result.contains("channels.php"))
    }

    // MARK: - Position Tests

    @Test func addsTrustedProxiesAsFirstMiddlewareCall() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        // trustProxies should appear before encryptCookies
        let trustProxiesIndex = result.range(of: "trustProxies")!.lowerBound
        let encryptCookiesIndex = result.range(of: "encryptCookies")!.lowerBound
        #expect(trustProxiesIndex < encryptCookiesIndex)
    }

    @Test func addsTrustedProxiesInsideMiddlewareCallback() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        // trustProxies should appear after withMiddleware opening
        let withMiddlewareIndex = result.range(of: "withMiddleware(function")!.lowerBound
        let trustProxiesIndex = result.range(of: "trustProxies")!.lowerBound
        #expect(trustProxiesIndex > withMiddlewareIndex)

        // trustProxies should appear before withExceptions
        let withExceptionsIndex = result.range(of: "withExceptions")!.lowerBound
        #expect(trustProxiesIndex < withExceptionsIndex)
    }

    // MARK: - Idempotency Tests

    @Test func doesNotDuplicateTrustProxiesIfAlreadyPresent() {
        let result = BootstrapAppEditor.addTrustedProxies(in: bootstrapWithTrustProxies)

        // Should remain unchanged
        #expect(result == bootstrapWithTrustProxies)
    }

    @Test func applyingTwiceProducesSameResult() {
        let firstPass = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)
        let secondPass = BootstrapAppEditor.addTrustedProxies(in: firstPass)

        #expect(firstPass == secondPass)
    }

    @Test func applyingTwiceDoesNotDuplicateContent() {
        let firstPass = BootstrapAppEditor.addTrustedProxies(in: vueStarterBootstrap)
        let secondPass = BootstrapAppEditor.addTrustedProxies(in: firstPass)

        // Count occurrences of trustProxies
        let count = secondPass.components(separatedBy: "trustProxies").count - 1
        #expect(count == 1)
    }

    // MARK: - Preservation Tests

    @Test func preservesExistingMiddleware() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        #expect(result.contains("encryptCookies"))
        #expect(result.contains("HandleAppearance::class"))
        #expect(result.contains("HandleInertiaRequests::class"))
        #expect(result.contains("AddLinkHeadersForPreloadedAssets::class"))
    }

    @Test func preservesRouting() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        #expect(result.contains("withRouting"))
        #expect(result.contains("web.php"))
        #expect(result.contains("console.php"))
        #expect(result.contains("/up"))
    }

    @Test func preservesExceptions() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        #expect(result.contains("withExceptions"))
    }

    @Test func preservesUseStatements() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        #expect(result.contains("use App\\Http\\Middleware\\HandleAppearance"))
        #expect(result.contains("use App\\Http\\Middleware\\HandleInertiaRequests"))
        #expect(result.contains("use Illuminate\\Foundation\\Application"))
    }

    @Test func preservesChannelsRouting() {
        let result = BootstrapAppEditor.addTrustedProxies(in: bootstrapWithChannels)

        #expect(result.contains("channels: __DIR__.'/../routes/channels.php'"))
    }

    // MARK: - Indentation Tests

    @Test func matchesExistingIndentation() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        // The trustProxies line should have the same indentation as encryptCookies
        let lines = result.components(separatedBy: .newlines)
        let trustProxiesLine = lines.first { $0.contains("$middleware->trustProxies") }
        let encryptCookiesLine = lines.first { $0.contains("$middleware->encryptCookies") }

        #expect(trustProxiesLine != nil)
        #expect(encryptCookiesLine != nil)

        let trustProxiesIndent = trustProxiesLine!.prefix(while: { $0.isWhitespace })
        let encryptCookiesIndent = encryptCookiesLine!.prefix(while: { $0.isWhitespace })

        #expect(trustProxiesIndent == encryptCookiesIndent)
    }

    @Test func arrayItemsHaveProperIndentation() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        let lines = result.components(separatedBy: .newlines)
        let trustProxiesLine = lines.first { $0.contains("$middleware->trustProxies") }
        let ipLine = lines.first { $0.contains("'10.0.0.0/8'") }

        #expect(trustProxiesLine != nil)
        #expect(ipLine != nil)

        let trustProxiesIndent = trustProxiesLine!.prefix(while: { $0.isWhitespace })
        let ipIndent = ipLine!.prefix(while: { $0.isWhitespace })

        // IP line should have 4 more spaces of indentation than the trustProxies line
        #expect(ipIndent.count == trustProxiesIndent.count + 4)
    }

    // MARK: - Content Validation Tests

    @Test func includesAllDockerNetworkRanges() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        // All three Docker network ranges should be present
        #expect(result.contains("'10.0.0.0/8'"))       // Docker Swarm overlay
        #expect(result.contains("'172.16.0.0/12'"))    // Docker bridge
        #expect(result.contains("'192.168.0.0/16'"))   // Private networks
    }

    @Test func includesCommentsForNetworkRanges() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        #expect(result.contains("// Docker Swarm overlay networks"))
        #expect(result.contains("// Docker bridge networks"))
        #expect(result.contains("// Private networks"))
    }

    // MARK: - Syntax Validation Tests

    @Test func producesValidPHPSyntax() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        // Check for balanced brackets
        let openBrackets = result.filter { $0 == "[" }.count
        let closeBrackets = result.filter { $0 == "]" }.count
        #expect(openBrackets == closeBrackets)

        // Check for balanced parentheses
        let openParens = result.filter { $0 == "(" }.count
        let closeParens = result.filter { $0 == ")" }.count
        #expect(openParens == closeParens)

        // Check for balanced braces
        let openBraces = result.filter { $0 == "{" }.count
        let closeBraces = result.filter { $0 == "}" }.count
        #expect(openBraces == closeBraces)
    }

    @Test func endsWithSemicolonAfterTrustProxies() {
        let result = BootstrapAppEditor.addTrustedProxies(in: reactStarterBootstrap)

        // Find the line with the closing bracket of trustProxies
        let lines = result.components(separatedBy: .newlines)
        let closingLine = lines.first { $0.contains("]);") && !$0.contains("encryptCookies") && !$0.contains("web(") }

        #expect(closingLine != nil)
        #expect(closingLine!.trimmingCharacters(in: .whitespaces).hasSuffix("]);"))
    }
}
