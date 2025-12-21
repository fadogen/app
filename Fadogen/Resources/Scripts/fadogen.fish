#!/usr/bin/env fish

# Fadogen - Development Environment Manager
# Fish shell version - manages PHP, Node.js, and Bun versions using project-specific config files

# ============================================================================
# Environment Variables
# ============================================================================

# FADOGEN_BASE is set by the shell config file (~/.config/fish/conf.d/fadogen.fish)
# This allows automatic switching between Debug (Fadogen-Dev) and Release (Fadogen) builds
set -gx FADOGEN_BIN "$FADOGEN_BASE/bin"
set -gx FADOGEN_CONFIG "$FADOGEN_BASE/config/php"
set -gx FADOGEN_NODE_VERSIONS "/Users/Shared/Fadogen/node"

# npm global modules: Each Node.js version has its own global modules
# in /Users/Shared/Fadogen/node/{major}/lib/node_modules (npm default behavior)
# This matches nvm's approach and ensures version isolation.

# Export INI_SCAN_DIR for all installed PHP versions
for php_bin in "$FADOGEN_BIN"/php[0-9]*
    # Skip if not a file
    test -f "$php_bin"; or continue

    # Skip FPM binaries
    string match -q '*-fpm*' "$php_bin"; and continue

    # Extract version number (php84 -> 84)
    set -l version_short (basename "$php_bin" | string replace 'php' '')
    set -l config_dir "$FADOGEN_CONFIG/$version_short/"

    if test -d "$config_dir"
        set -gx "FADOGEN_PHP_{$version_short}_INI_SCAN_DIR" "$config_dir"
    end
end

# ============================================================================
# Helper Functions - Version Detection
# ============================================================================

# Find .fadogen file and extract PHP version
function _fadogen_find_php_version
    set -l dir $PWD
    while test "$dir" != "/"
        if test -f "$dir/.fadogen"
            # Extract PHP version from TOML: [php]\nversion = "8.4"
            awk '
                /^\[php\]/ { in_section=1; next }
                /^\[/ && in_section { exit }
                in_section && /^version[[:space:]]*=/ {
                    gsub(/^version[[:space:]]*=[[:space:]]*"|"[[:space:]]*$/, "")
                    print
                    exit
                }
            ' "$dir/.fadogen" | string trim
            return 0
        end
        set dir (dirname "$dir")
    end
    return 1
end

# Find Node.js version from .fadogen or .nvmrc (fallback for compatibility)
function _fadogen_find_node_version
    set -l dir $PWD
    while test "$dir" != "/"
        # Priority 1: Check .fadogen
        if test -f "$dir/.fadogen"
            # Extract Node version from TOML: [node]\nversion = "22"
            set -l version (awk '
                /^\[node\]/ { in_section=1; next }
                /^\[/ && in_section { exit }
                in_section && /^version[[:space:]]*=/ {
                    gsub(/^version[[:space:]]*=[[:space:]]*"|"[[:space:]]*$/, "")
                    print
                    exit
                }
            ' "$dir/.fadogen" | string trim)

            if test -n "$version"
                echo "$version"
                return 0
            end
        end

        # Priority 2: Check .nvmrc (fallback for ecosystem compatibility)
        if test -f "$dir/.nvmrc"
            head -n 1 "$dir/.nvmrc" | string trim
            return 0
        end

        set dir (dirname "$dir")
    end
    return 1
end

# Get Node.js binary path for a specific version
function _fadogen_get_node_path
    set -l version $argv[1]
    echo "$FADOGEN_NODE_VERSIONS/$version/bin/node"
end

# ============================================================================
# Wrapper Execution Functions (DRY)
# ============================================================================

# Execute Node.js tool with version detection (.fadogen or .nvmrc)
# Used by: node-wrapper, npm-wrapper, npx-wrapper
function _fadogen_exec_node_tool
    set -l tool_name $argv[1]
    set -e argv[1]  # Remove first argument

    # Try to find version
    set -l version (_fadogen_find_node_version)

    if test -n "$version"
        # Version found, use specific version
        set -l tool_bin "$FADOGEN_NODE_VERSIONS/$version/bin/$tool_name"
        set -l node_bin "$FADOGEN_NODE_VERSIONS/$version/bin/node"

        if test -f "$tool_bin"
            switch $tool_name
                case npm
                    # npm needs NODE env var set
                    env NODE="$node_bin" "$tool_bin" $argv
                    return $status
                case npx
                    # npx needs node bin directory in PATH
                    env PATH=(dirname "$node_bin"):$PATH "$tool_bin" $argv
                    return $status
                case '*'
                    # node and others: direct execution
                    exec "$tool_bin" $argv
            end
        else
            echo "Error: Node.js $version not installed" >&2
            echo "Please install Node.js $version using Fadogen" >&2
            return 1
        end
    end

    # No version config, use default
    switch $tool_name
        case npm npx
            # Resolve from node.default symlink
            set -l default_node_path (readlink "$FADOGEN_BIN/node.default" 2>/dev/null)
            if test -z "$default_node_path"
                echo "Error: No default Node.js version configured" >&2
                echo "Please set a default Node.js version using Fadogen" >&2
                return 1
            end

            if not test -f "$default_node_path"
                echo "Error: Default Node.js symlink is broken" >&2
                echo "Please reinstall Node.js using Fadogen" >&2
                return 1
            end

            set -l default_node_dir (dirname "$default_node_path")
            set -l default_tool_path "$default_node_dir/$tool_name"

            if test "$tool_name" = "npx"
                env PATH="$default_node_dir":$PATH "$default_tool_path" $argv
            else
                env NODE="$default_node_path" "$default_tool_path" $argv
            end
            return $status
        case '*'
            # For node: use .default symlink
            if not test -f "$FADOGEN_BIN/$tool_name.default"
                echo "Error: No default Node.js version configured" >&2
                echo "Please set a default Node.js version using Fadogen" >&2
                return 1
            end
            exec "$FADOGEN_BIN/$tool_name.default" $argv
    end
end

# Execute PHP with version detection (.fadogen)
# Used by: php-wrapper
function _fadogen_exec_php_tool
    # Try to find PHP version
    set -l version (_fadogen_find_php_version)

    if test -n "$version"
        # .fadogen found, use specific version (8.4 -> php84)
        set -l version_short (string replace -a '.' '' "$version")
        set -l php_bin "$FADOGEN_BIN/php$version_short"

        if test -f "$php_bin"
            # Export INI_SCAN_DIR for this version
            set -l config_dir "$FADOGEN_CONFIG/$version_short/"
            if test -d "$config_dir"
                set -gx PHP_INI_SCAN_DIR "$config_dir"
            end
            exec "$php_bin" $argv
        else
            echo "Error: PHP $version not installed" >&2
            echo "Please install PHP $version using Fadogen" >&2
            return 1
        end
    end

    # No .fadogen, use default version
    if test -f "$FADOGEN_BIN/php.default"
        exec "$FADOGEN_BIN/php.default" $argv
    else
        echo "Error: No default PHP version configured" >&2
        echo "Please install PHP using Fadogen" >&2
        return 1
    end
end

# ============================================================================
# Fadogen CLI Command
# ============================================================================

# Main fadogen command router
function fadogen
    switch $argv[1]
        case 'php:ext'
            set -e argv[1]
            "$FADOGEN_BIN/fadogen-ext" $argv
        case '--help' '-h' 'help'
            echo "Fadogen - Development Environment Manager"
            echo ""
            echo "Commands:"
            echo "  php:ext install <ext>   Install PHP extension via PECL"
            echo "  php:ext list            List installed PHP extensions"
            echo "  php:ext remove <ext>    Remove PHP extension"
            echo ""
            echo "Run 'fadogen <command> --help' for more information."
        case '*'
            echo "Fadogen - Development Environment Manager"
            echo ""
            echo "Usage: fadogen <command> [options]"
            echo ""
            echo "Commands:"
            echo "  php:ext    Manage PHP extensions"
            echo ""
            echo "Run 'fadogen --help' for more information."
    end
end
