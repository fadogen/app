import SwiftUI
import AppKit

/// Toolbar button for GitHub actions with 3 states:
/// 1. Repo detected → Opens browser to GitHub URL
/// 2. No GitHub integration → Shows IntegrationSheet
/// 3. Integration exists, no repo → Shows repo creation popover
struct GitHubToolbarButton: View {
    let project: LocalProject
    let githubIntegration: Integration?
    @Binding var showingAddIntegration: IntegrationType?
    @Binding var showingGitHubPopover: Bool

    var body: some View {
        Button {
            handleButtonTap()
        } label: {
            Label {
                Text(buttonLabel)
            } icon: {
                Image("github")
                    .renderingMode(.template)
            }
        }
        .help(buttonHelp)
    }

    private var buttonLabel: String {
        if project.gitHubURL != nil {
            return "Open on GitHub"
        } else if githubIntegration == nil {
            return "Add GitHub"
        } else {
            return "Create Repository"
        }
    }

    private var buttonHelp: String {
        if project.gitHubURL != nil {
            return "Open repository on GitHub"
        } else if githubIntegration == nil {
            return "Add GitHub integration to create repositories"
        } else {
            return "Create a new GitHub repository for this project"
        }
    }

    private func handleButtonTap() {
        // State 1: Repo detected - open in browser
        if let gitHubURL = project.gitHubURL {
            NSWorkspace.shared.open(gitHubURL)
            return
        }

        // State 2: No GitHub integration - show add integration sheet
        if githubIntegration == nil {
            showingAddIntegration = .github
            return
        }

        // State 3: Integration exists but no repo - show creation popover
        showingGitHubPopover = true
    }
}
