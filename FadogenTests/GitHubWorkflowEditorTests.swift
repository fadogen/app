import Foundation
import Testing
@testable import Fadogen

@MainActor
struct GitHubWorkflowEditorTests {

    // MARK: - Test Fixtures

    /// Sample lint.yml workflow with npm
    let lintWorkflowNpm = """
        name: linter

        on:
          push:
            branches:
              - develop
              - main
          pull_request:
            branches:
              - develop
              - main

        permissions:
          contents: write

        jobs:
          quality:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v5

              - name: Setup PHP
                uses: shivammathur/setup-php@v2
                with:
                  php-version: '8.4'

              - name: Install Dependencies
                run: |
                  composer install -q --no-ansi --no-interaction --no-scripts --no-progress --prefer-dist
                  npm install

              - name: Run Pint
                run: vendor/bin/pint

              - name: Format Frontend
                run: npm run format

              - name: Lint Frontend
                run: npm run lint
        """

    /// Sample tests.yml workflow with npm
    let testsWorkflowNpm = """
        name: tests

        on:
          push:
            branches:
              - develop
              - main
          pull_request:
            branches:
              - develop
              - main

        jobs:
          ci:
            runs-on: ubuntu-latest

            steps:
              - name: Checkout
                uses: actions/checkout@v4

              - name: Setup PHP
                uses: shivammathur/setup-php@v2
                with:
                  php-version: 8.4
                  tools: composer:v2
                  coverage: xdebug

              - name: Setup Node
                uses: actions/setup-node@v4
                with:
                  node-version: '22'
                  cache: 'npm'

              - name: Install Node Dependencies
                run: npm ci

              - name: Install Dependencies
                run: composer install --no-interaction --prefer-dist --optimize-autoloader

              - name: Build Assets
                run: npm run build

              - name: Copy Environment File
                run: cp .env.example .env

              - name: Generate Application Key
                run: php artisan key:generate

              - name: Tests
                run: ./vendor/bin/pest
        """

    /// Sample workflow already using Bun
    let workflowWithBun = """
        name: tests

        jobs:
          ci:
            runs-on: ubuntu-latest
            steps:
              - name: Setup Bun
                uses: oven-sh/setup-bun@v2

              - name: Install Node Dependencies
                run: bun install --frozen-lockfile

              - name: Build Assets
                run: bun run build
        """

    /// Workflow without any Node/npm setup
    let workflowWithoutNode = """
        name: php-only

        jobs:
          ci:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4

              - name: Setup PHP
                uses: shivammathur/setup-php@v2
                with:
                  php-version: 8.4

              - name: Install Dependencies
                run: composer install

              - name: Tests
                run: ./vendor/bin/pest
        """

    /// Workflow with setup-node v3
    let workflowWithOlderNodeVersion = """
        name: tests

        jobs:
          ci:
            runs-on: ubuntu-latest
            steps:
              - name: Setup Node
                uses: actions/setup-node@v3
                with:
                  node-version: '20'
                  cache: 'npm'

              - name: Install
                run: npm install
        """

    /// Workflow with node-version without quotes
    let workflowWithUnquotedNodeVersion = """
        name: tests

        jobs:
          ci:
            runs-on: ubuntu-latest
            steps:
              - name: Setup Node
                uses: actions/setup-node@v4
                with:
                  node-version: 22
                  cache: npm

              - name: Install
                run: npm ci
        """

    // MARK: - Setup Action Replacement Tests

    @Test func replacesSetupNodeWithSetupBun() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("uses: oven-sh/setup-bun@v2"))
        #expect(!result.contains("actions/setup-node"))
    }

    @Test func replacesOlderSetupNodeVersions() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: workflowWithOlderNodeVersion)

        #expect(result.contains("uses: oven-sh/setup-bun@v2"))
        #expect(!result.contains("actions/setup-node@v3"))
    }

    @Test func renamesSetupNodeStepToSetupBun() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("- name: Setup Bun"))
        #expect(!result.contains("- name: Setup Node"))
    }

    // MARK: - Line Removal Tests

    @Test func removesNodeVersionLine() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(!result.contains("node-version:"))
    }

    @Test func removesUnquotedNodeVersionLine() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: workflowWithUnquotedNodeVersion)

        #expect(!result.contains("node-version:"))
    }

    @Test func removesCacheNpmLine() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(!result.contains("cache: 'npm'"))
        #expect(!result.contains("cache: npm"))
    }

    @Test func removesEmptyWithBlock() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        // The 'with:' block for setup-bun should be removed since it only contained node-version and cache
        // But the 'with:' block for setup-php should remain
        #expect(result.contains("uses: oven-sh/setup-bun@v2\n\n      - name:"))
        // PHP setup should still have its with block
        #expect(result.contains("shivammathur/setup-php@v2\n        with:"))
    }

    // MARK: - Command Replacement Tests

    @Test func replacesNpmCiWithBunInstallFrozenLockfile() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("bun install --frozen-lockfile"))
        #expect(!result.contains("npm ci"))
    }

    @Test func replacesNpmInstallWithBunInstall() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)

        #expect(result.contains("bun install"))
        #expect(!result.contains("npm install"))
    }

    @Test func replacesNpmRunWithBunRun() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("bun run build"))
        #expect(!result.contains("npm run build"))
    }

    @Test func replacesMultipleNpmRunCommands() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)

        #expect(result.contains("bun run format"))
        #expect(result.contains("bun run lint"))
        #expect(!result.contains("npm run format"))
        #expect(!result.contains("npm run lint"))
    }

    // MARK: - Preservation Tests

    @Test func preservesPhpSetup() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("shivammathur/setup-php@v2"))
        #expect(result.contains("php-version: 8.4"))
    }

    @Test func preservesComposerCommands() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("composer install"))
    }

    @Test func preservesPintCommand() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)

        #expect(result.contains("vendor/bin/pint"))
    }

    @Test func preservesArtisanCommands() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("php artisan key:generate"))
    }

    @Test func preservesPestCommand() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("./vendor/bin/pest"))
    }

    @Test func preservesCheckoutAction() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("actions/checkout@v4"))
    }

    @Test func preservesWorkflowStructure() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        #expect(result.contains("name: tests"))
        #expect(result.contains("jobs:"))
        #expect(result.contains("runs-on: ubuntu-latest"))
        #expect(result.contains("steps:"))
    }

    // MARK: - Edge Cases

    @Test func handlesWorkflowWithoutNode() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: workflowWithoutNode)

        // Should remain mostly unchanged
        #expect(result.contains("shivammathur/setup-php@v2"))
        #expect(result.contains("composer install"))
        // Use specific patterns to avoid matching "ubuntu" which contains "bun"
        #expect(!result.contains("bun install"))
        #expect(!result.contains("bun run"))
        #expect(!result.contains("oven-sh"))
    }

    @Test func handlesEmptyContent() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: "")

        #expect(result == "")
    }

    // MARK: - Idempotency Tests

    @Test func doesNotModifyIfAlreadyUsingBun() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: workflowWithBun)

        // Should remain unchanged
        #expect(result == workflowWithBun)
    }

    @Test func applyingTwiceProducesSameResult() {
        let firstPass = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)
        let secondPass = GitHubWorkflowEditor.replaceNpmWithBun(in: firstPass)

        #expect(firstPass == secondPass)
    }

    @Test func applyingTwiceToLintProducesSameResult() {
        let firstPass = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)
        let secondPass = GitHubWorkflowEditor.replaceNpmWithBun(in: firstPass)

        #expect(firstPass == secondPass)
    }

    // MARK: - Full Transformation Tests

    @Test func fullyTransformsTestsWorkflow() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: testsWorkflowNpm)

        // All npm references should be gone
        #expect(!result.contains("npm "))
        #expect(!result.contains("npm\""))
        #expect(!result.contains("actions/setup-node"))
        #expect(!result.contains("node-version"))
        #expect(!result.contains("cache: 'npm'"))

        // All bun references should be present
        #expect(result.contains("oven-sh/setup-bun@v2"))
        #expect(result.contains("bun install"))
        #expect(result.contains("bun run build"))
    }

    @Test func fullyTransformsLintWorkflow() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)

        // All npm references should be gone
        #expect(!result.contains("npm "))

        // All bun references should be present
        #expect(result.contains("bun install"))
        #expect(result.contains("bun run format"))
        #expect(result.contains("bun run lint"))
    }

    // MARK: - Setup Bun Injection Tests

    @Test func addsSetupBunWhenMissingButBunCommandsExist() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)

        // Setup Bun should be added since npm commands were replaced with bun
        #expect(result.contains("oven-sh/setup-bun@v2"))
        #expect(result.contains("- name: Setup Bun"))
    }

    @Test func doesNotAddDuplicateSetupBun() {
        // First pass adds setup-bun
        let firstPass = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)
        // Second pass should not add another
        let secondPass = GitHubWorkflowEditor.replaceNpmWithBun(in: firstPass)

        // Count occurrences of setup-bun - should be exactly 1
        let count = secondPass.components(separatedBy: "oven-sh/setup-bun@v2").count - 1
        #expect(count == 1)
    }

    @Test func setupBunAddedAfterPhpSetup() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)

        // Find positions
        guard let phpPos = result.range(of: "shivammathur/setup-php"),
              let bunPos = result.range(of: "oven-sh/setup-bun") else {
            Issue.record("Could not find PHP or Bun setup")
            return
        }

        // Bun setup should come after PHP setup
        #expect(bunPos.lowerBound > phpPos.lowerBound)
    }

    @Test func setupBunAddedBeforeInstallDependencies() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)

        // Find positions
        guard let bunPos = result.range(of: "oven-sh/setup-bun"),
              let installPos = result.range(of: "Install Dependencies") else {
            Issue.record("Could not find Setup Bun or Install Dependencies")
            return
        }

        // Bun setup MUST come BEFORE Install Dependencies
        #expect(bunPos.lowerBound < installPos.lowerBound, "Setup Bun must appear before Install Dependencies step")
    }

    @Test func setupBunHasCorrectIndentation() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)
        let lines = result.components(separatedBy: "\n")

        // Find the Setup Bun line
        guard let bunLineIndex = lines.firstIndex(where: { $0.contains("- name: Setup Bun") }) else {
            Issue.record("Could not find Setup Bun line")
            return
        }

        // Find the Install Dependencies line to compare indentation
        guard let installLineIndex = lines.firstIndex(where: { $0.contains("- name: Install Dependencies") }) else {
            Issue.record("Could not find Install Dependencies line")
            return
        }

        let bunIndent = lines[bunLineIndex].prefix(while: { $0 == " " || $0 == "\t" })
        let installIndent = lines[installLineIndex].prefix(while: { $0 == " " || $0 == "\t" })

        // Both should have the same indentation
        #expect(bunIndent == installIndent, "Setup Bun should have same indentation as other steps")
    }

    @Test func setupBunUsesLineHasCorrectIndentation() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)
        let lines = result.components(separatedBy: "\n")

        // Find the Setup Bun step's uses line
        guard let bunNameIndex = lines.firstIndex(where: { $0.contains("- name: Setup Bun") }),
              bunNameIndex + 1 < lines.count else {
            Issue.record("Could not find Setup Bun step")
            return
        }

        let usesLine = lines[bunNameIndex + 1]
        #expect(usesLine.contains("uses: oven-sh/setup-bun@v2"), "Next line after Setup Bun name should be the uses line")

        // The uses line should have 2 more spaces than the name line
        let nameIndent = lines[bunNameIndex].prefix(while: { $0 == " " || $0 == "\t" }).count
        let usesIndent = usesLine.prefix(while: { $0 == " " || $0 == "\t" }).count

        #expect(usesIndent == nameIndent + 2, "Uses line should be indented 2 spaces more than name line")
    }

    @Test func setupBunPositionInFullWorkflowOutput() {
        let result = GitHubWorkflowEditor.replaceNpmWithBun(in: lintWorkflowNpm)

        // Verify the exact order of steps in the output
        let setupPhpPos = result.range(of: "shivammathur/setup-php")!.lowerBound
        let setupBunPos = result.range(of: "oven-sh/setup-bun")!.lowerBound
        let installDepsPos = result.range(of: "Install Dependencies")!.lowerBound
        let runPintPos = result.range(of: "Run Pint")!.lowerBound

        // Verify order: PHP -> Bun -> Install -> Pint
        #expect(setupPhpPos < setupBunPos, "Setup PHP should come before Setup Bun")
        #expect(setupBunPos < installDepsPos, "Setup Bun should come before Install Dependencies")
        #expect(installDepsPos < runPintPos, "Install Dependencies should come before Run Pint")
    }
}
