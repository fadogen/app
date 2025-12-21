#!/bin/sh

# Fadogen - Development Environment Manager
# Manages PHP, Node.js, and Bun versions using project-specific config files

# ============================================================================
# Environment Variables
# ============================================================================

# FADOGEN_BASE is set by the shell config file (.zshenv, .bash_profile, etc.)
# This allows automatic switching between Debug (Fadogen-Dev) and Release (Fadogen) builds
FADOGEN_BIN="$FADOGEN_BASE/bin"
FADOGEN_CONFIG="$FADOGEN_BASE/config/php"
FADOGEN_NODE_VERSIONS="/Users/Shared/Fadogen/node"

# npm global modules: Each Node.js version has its own global modules
# in /Users/Shared/Fadogen/node/{major}/lib/node_modules (npm default behavior)
# This matches nvm's approach and ensures version isolation.

# Export INI_SCAN_DIR for all installed PHP versions
for php_bin in "$FADOGEN_BIN"/php[0-9]*; do
    [ -f "$php_bin" ] || continue
    case "$php_bin" in
        *-fpm*) continue ;;
    esac

    # Extract version number (php84 -> 84)
    version_short=$(basename "$php_bin" | sed 's/php//')
    config_dir="$FADOGEN_CONFIG/${version_short}/"

    if [ -d "$config_dir" ]; then
        export "FADOGEN_PHP_${version_short}_INI_SCAN_DIR=$config_dir"
    fi
done

# ============================================================================
# Helper Functions - Version Detection
# ============================================================================

# Find .fadogen file and extract PHP version
_fadogen_find_php_version() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.fadogen" ]; then
            # Extract PHP version from TOML: [php]\nversion = "8.4"
            awk '
                /^\[php\]/ { in_section=1; next }
                /^\[/ && in_section { exit }
                in_section && /^version[[:space:]]*=/ {
                    gsub(/^version[[:space:]]*=[[:space:]]*"|"[[:space:]]*$/, "")
                    print
                    exit
                }
            ' "$dir/.fadogen" | tr -d '[:space:]'
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Find Node.js version from .fadogen or .nvmrc (fallback for compatibility)
_fadogen_find_node_version() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        # Priority 1: Check .fadogen
        if [ -f "$dir/.fadogen" ]; then
            # Extract Node version from TOML: [node]\nversion = "22"
            local version=$(awk '
                /^\[node\]/ { in_section=1; next }
                /^\[/ && in_section { exit }
                in_section && /^version[[:space:]]*=/ {
                    gsub(/^version[[:space:]]*=[[:space:]]*"|"[[:space:]]*$/, "")
                    print
                    exit
                }
            ' "$dir/.fadogen" | tr -d '[:space:]')

            if [ -n "$version" ]; then
                echo "$version"
                return 0
            fi
        fi

        # Priority 2: Check .nvmrc (fallback for ecosystem compatibility)
        if [ -f "$dir/.nvmrc" ]; then
            head -n 1 "$dir/.nvmrc" | tr -d '[:space:]'
            return 0
        fi

        dir=$(dirname "$dir")
    done
    return 1
}

# Get Node.js binary path for a specific version
_fadogen_get_node_path() {
    local version="$1"
    echo "$FADOGEN_NODE_VERSIONS/$version/bin/node"
}

# ============================================================================
# Wrapper Execution Functions (DRY)
# ============================================================================

# Execute Node.js tool with version detection (.fadogen or .nvmrc)
# Used by: node-wrapper, npm-wrapper, npx-wrapper
_fadogen_exec_node_tool() {
    local tool_name="$1"
    shift

    # Try to find version
    local version=$(_fadogen_find_node_version)

    if [ -n "$version" ]; then
        # Version found, use specific version
        local tool_bin="$FADOGEN_NODE_VERSIONS/$version/bin/$tool_name"
        local node_bin="$FADOGEN_NODE_VERSIONS/$version/bin/node"

        if [ -f "$tool_bin" ]; then
            # Execute based on tool type
            case "$tool_name" in
                npm)
                    # npm needs NODE env var set
                    exec env NODE="$node_bin" "$tool_bin" "$@"
                    ;;
                npx)
                    # npx is a shell script that uses #!/usr/bin/env node
                    # Prepend node bin directory to PATH
                    exec env PATH="$(dirname "$node_bin"):$PATH" "$tool_bin" "$@"
                    ;;
                *)
                    # node and others: direct execution
                    exec "$tool_bin" "$@"
                    ;;
            esac
        else
            echo "Error: Node.js $version not installed" >&2
            echo "Please install Node.js $version using Fadogen" >&2
            exit 1
        fi
    fi

    # No version config, use default
    case "$tool_name" in
        npm|npx)
            # For npm/npx, resolve from node.default symlink
            local default_node_path
            if ! default_node_path=$(readlink "$FADOGEN_BIN/node.default" 2>/dev/null); then
                echo "Error: No default Node.js version configured" >&2
                echo "Please set a default Node.js version using Fadogen" >&2
                exit 1
            fi

            # Verify symlink target exists
            if [ ! -f "$default_node_path" ]; then
                echo "Error: Default Node.js symlink is broken" >&2
                echo "Please reinstall Node.js using Fadogen" >&2
                exit 1
            fi

            local default_node_dir
            default_node_dir=$(dirname "$default_node_path")
            local default_tool_path="$default_node_dir/$tool_name"

            if [ "$tool_name" = "npx" ]; then
                exec env PATH="$default_node_dir:$PATH" "$default_tool_path" "$@"
            else
                exec env NODE="$default_node_path" "$default_tool_path" "$@"
            fi
            ;;
        *)
            # For node: use .default symlink
            if [ ! -f "$FADOGEN_BIN/$tool_name.default" ]; then
                echo "Error: No default Node.js version configured" >&2
                echo "Please set a default Node.js version using Fadogen" >&2
                exit 1
            fi
            exec "$FADOGEN_BIN/$tool_name.default" "$@"
            ;;
    esac
}

# Execute PHP with version detection (.fadogen)
# Used by: php-wrapper
_fadogen_exec_php_tool() {
    # Try to find PHP version
    local version=$(_fadogen_find_php_version)

    if [ -n "$version" ]; then
        # .fadogen found, use specific version (8.4 -> php84)
        local version_short=$(echo "$version" | tr -d '.')
        local php_bin="$FADOGEN_BIN/php${version_short}"

        if [ -f "$php_bin" ]; then
            # Export INI_SCAN_DIR for this version
            local config_dir="$FADOGEN_CONFIG/${version_short}/"
            if [ -d "$config_dir" ]; then
                export PHP_INI_SCAN_DIR="$config_dir"
            fi
            exec "$php_bin" "$@"
        else
            echo "Error: PHP $version not installed" >&2
            echo "Please install PHP $version using Fadogen" >&2
            exit 1
        fi
    fi

    # No .fadogen, use default version
    if [ -f "$FADOGEN_BIN/php.default" ]; then
        exec "$FADOGEN_BIN/php.default" "$@"
    else
        echo "Error: No default PHP version configured" >&2
        echo "Please install PHP using Fadogen" >&2
        exit 1
    fi
}

# ============================================================================
# Fadogen CLI Command
# ============================================================================

# Main fadogen command router
fadogen() {
    case "$1" in
        php:ext)
            shift
            "$FADOGEN_BIN/fadogen-ext" "$@"
            ;;
        --help|-h|help)
            echo "Fadogen - Development Environment Manager"
            echo ""
            echo "Commands:"
            echo "  php:ext install <ext>   Install PHP extension via PECL"
            echo "  php:ext list            List installed PHP extensions"
            echo "  php:ext remove <ext>    Remove PHP extension"
            echo ""
            echo "Run 'fadogen <command> --help' for more information."
            ;;
        *)
            echo "Fadogen - Development Environment Manager"
            echo ""
            echo "Usage: fadogen <command> [options]"
            echo ""
            echo "Commands:"
            echo "  php:ext    Manage PHP extensions"
            echo ""
            echo "Run 'fadogen --help' for more information."
            ;;
    esac
}
