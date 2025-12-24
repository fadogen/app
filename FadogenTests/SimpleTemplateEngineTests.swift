import Foundation
import Testing
@testable import Fadogen

@MainActor
struct SimpleTemplateEngineTests {
    // MARK: - Variable Replacement Tests

    @Test func replacesSimpleVariable() {
        let template = "Hello {{NAME}}!"
        let result = SimpleTemplateEngine.render(template, variables: ["NAME": "World"])

        #expect(result == "Hello World!\n")
    }

    @Test func replacesMultipleVariables() {
        let template = "{{GREETING}} {{NAME}}!"
        let result = SimpleTemplateEngine.render(
            template,
            variables: ["GREETING": "Hello", "NAME": "World"]
        )

        #expect(result == "Hello World!\n")
    }

    @Test func leavesUnknownVariablesUntouched() {
        let template = "Hello {{NAME}} and {{UNKNOWN}}!"
        let result = SimpleTemplateEngine.render(template, variables: ["NAME": "World"])

        #expect(result == "Hello World and {{UNKNOWN}}!\n")
    }

    @Test func handlesEmptyVariables() {
        let template = "Hello {{NAME}}!"
        let result = SimpleTemplateEngine.render(template, variables: [:])

        #expect(result == "Hello {{NAME}}!\n")
    }

    // MARK: - Conditional Tests

    @Test func includesContentWhenConditionTrue() {
        let template = "Start{{#IF SHOW}}Content{{/IF}}End"
        let result = SimpleTemplateEngine.render(template, conditions: ["SHOW": true])

        #expect(result.contains("Content"))
    }

    @Test func excludesContentWhenConditionFalse() {
        let template = "Start{{#IF SHOW}}Content{{/IF}}End"
        let result = SimpleTemplateEngine.render(template, conditions: ["SHOW": false])

        #expect(!result.contains("Content"))
        #expect(result.contains("Start"))
        #expect(result.contains("End"))
    }

    @Test func excludesContentWhenConditionMissing() {
        let template = "Start{{#IF UNKNOWN}}Content{{/IF}}End"
        let result = SimpleTemplateEngine.render(template, conditions: [:])

        #expect(!result.contains("Content"))
    }

    @Test func handlesMultipleConditions() {
        let template = "{{#IF A}}A{{/IF}}{{#IF B}}B{{/IF}}{{#IF C}}C{{/IF}}"
        let result = SimpleTemplateEngine.render(
            template,
            conditions: ["A": true, "B": false, "C": true]
        )

        #expect(result.contains("A"))
        #expect(!result.contains("B"))
        #expect(result.contains("C"))
    }

    @Test func handlesMultilineConditionalContent() {
        let template = """
            Start
            {{#IF SHOW}}
            Line 1
            Line 2
            {{/IF}}
            End
            """
        let result = SimpleTemplateEngine.render(template, conditions: ["SHOW": true])

        #expect(result.contains("Line 1"))
        #expect(result.contains("Line 2"))
    }

    // MARK: - Combined Tests

    @Test func handlesVariablesInsideConditionals() {
        let template = "{{#IF SHOW}}Hello {{NAME}}!{{/IF}}"
        let result = SimpleTemplateEngine.render(
            template,
            variables: ["NAME": "World"],
            conditions: ["SHOW": true]
        )

        #expect(result == "Hello World!\n")
    }

    @Test func handlesVariablesWhenConditionalExcluded() {
        let template = "{{#IF SHOW}}Hello {{NAME}}!{{/IF}}"
        let result = SimpleTemplateEngine.render(
            template,
            variables: ["NAME": "World"],
            conditions: ["SHOW": false]
        )

        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Dockerfile-like Template Tests

    @Test func rendersDockerfileStyleTemplate() {
        let template = """
            FROM base AS app
            {{#IF HAS_NODE}}
            COPY --from=node /app/build ./build
            {{/IF}}
            CMD ["php"]
            """

        let result = SimpleTemplateEngine.render(template, conditions: ["HAS_NODE": true])

        #expect(result.contains("FROM base AS app"))
        #expect(result.contains("COPY --from=node"))
        #expect(result.contains("CMD"))
    }

    @Test func rendersDockerfileWithVariablesAndConditions() {
        let template = """
            {{#IF HAS_NODE}}
            FROM {{NODE_IMAGE}} AS node
            RUN {{INSTALL_CMD}}
            {{/IF}}
            """

        let result = SimpleTemplateEngine.render(
            template,
            variables: ["NODE_IMAGE": "oven/bun:1", "INSTALL_CMD": "bun install"],
            conditions: ["HAS_NODE": true]
        )

        #expect(result.contains("FROM oven/bun:1 AS node"))
        #expect(result.contains("RUN bun install"))
    }

    // MARK: - Inline Conditional Tests (Shell Continuation)

    @Test func inlineConditionalIncludesContentWhenTrue() {
        let template = """
            RUN mkdir -p dir && \\
            {{#IF HAS_EXTRA}}    extra-command && \\
            {{/IF}}    final-command
            """

        let result = SimpleTemplateEngine.render(template, conditions: ["HAS_EXTRA": true])

        #expect(result.contains("extra-command"))
        #expect(result.contains("final-command"))
    }

    @Test func inlineConditionalExcludesContentWhenFalse() {
        let template = """
            RUN mkdir -p dir && \\
            {{#IF HAS_EXTRA}}    extra-command && \\
            {{/IF}}    final-command
            """

        let result = SimpleTemplateEngine.render(template, conditions: ["HAS_EXTRA": false])

        #expect(!result.contains("extra-command"))
        #expect(result.contains("final-command"))
    }

    @Test func inlineConditionalProducesValidShellContinuation() {
        // This test verifies that when condition is false, we don't get empty lines
        // that would break shell continuation (backslash must be followed by content)
        let template = """
            RUN echo "start" && \\
            {{#IF INCLUDE}}    echo "middle" && \\
            {{/IF}}    echo "end"
            """

        let result = SimpleTemplateEngine.render(template, conditions: ["INCLUDE": false])

        // Should produce valid shell: RUN echo "start" && \
        //     echo "end"
        // NOT: RUN echo "start" && \
        //                          <- empty line would break shell
        //     echo "end"

        let lines = result.components(separatedBy: "\n")
        // Find the line with backslash continuation
        if let backslashLineIndex = lines.firstIndex(where: { $0.hasSuffix("\\") }) {
            let nextLineIndex = backslashLineIndex + 1
            if nextLineIndex < lines.count {
                let nextLine = lines[nextLineIndex]
                // Next line after backslash should have content (not be empty)
                #expect(!nextLine.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @Test func symfonyDockerfilePatternWhenTrue() {
        let template = """
            RUN --mount=type=secret,id=dotenv \\
                mkdir -p public/bundles && \\
            {{#IF HAS_ASSET_MAPPER}}    php bin/console importmap:install --env=prod && \\
            {{/IF}}    php bin/console cache:clear --env=prod
            """

        let result = SimpleTemplateEngine.render(template, conditions: ["HAS_ASSET_MAPPER": true])

        #expect(result.contains("importmap:install"))
        #expect(result.contains("cache:clear"))
    }

    @Test func symfonyDockerfilePatternWhenFalse() {
        let template = """
            RUN --mount=type=secret,id=dotenv \\
                mkdir -p public/bundles && \\
            {{#IF HAS_ASSET_MAPPER}}    php bin/console importmap:install --env=prod && \\
            {{/IF}}    php bin/console cache:clear --env=prod
            """

        let result = SimpleTemplateEngine.render(template, conditions: ["HAS_ASSET_MAPPER": false])

        #expect(!result.contains("importmap:install"))
        #expect(result.contains("cache:clear"))
        #expect(result.contains("mkdir -p public/bundles"))
    }
}
