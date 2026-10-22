import Foundation

enum VMTools {
    static let catalogScript = #"""
    set -eu
    umask 022
    catalog=/opt/homebrew/Library/Taps/homebrew/homebrew-core
    if [ -e "$catalog" ] || [ -L "$catalog" ]; then
        if [ ! -L "$catalog" ] && [ -d "$catalog/.git" ] && [ ! -L "$catalog/.git" ] &&
            /usr/bin/git --git-dir="$catalog/.git" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
            exit 0
        fi
        printf '%s\n' 'The VM Homebrew catalog already exists but is not a valid repository. Its files were preserved.' >&2
        exit 1
    fi
    parent=${catalog%/*}
    /bin/mkdir -p "$parent"
    stage=$(/usr/bin/mktemp -d "$parent/.comet-catalog.XXXXXX")
    trap '/bin/rm -rf "$stage"' EXIT
    /usr/bin/git clone --depth 1 --single-branch --branch main -- https://github.com/Homebrew/homebrew-core.git "$stage/core"
    if [ ! -d "$stage/core/.git" ] || [ -L "$stage/core/.git" ] ||
        ! /usr/bin/git --git-dir="$stage/core/.git" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
        printf '%s\n' 'The downloaded VM Homebrew catalog is invalid. No existing files were replaced.' >&2
        exit 1
    fi
    if [ -e "$catalog" ] || [ -L "$catalog" ]; then
        printf '%s\n' 'The VM Homebrew catalog appeared during setup. Its files were preserved.' >&2
        exit 1
    fi
    /bin/mv "$stage/core" "$catalog"
    """#

    static let statusScript = #"""
    developer=$(/usr/bin/xcode-select -p 2>/dev/null) || exit 0
    [ -d "$developer" ] || exit 0
    /usr/bin/xcrun --find git >/dev/null 2>&1 || exit 0
    /usr/bin/xcrun --find clang >/dev/null 2>&1 || exit 0
    [ -x /opt/homebrew/bin/brew ] || exit 0
    [ "$(/opt/homebrew/bin/brew --prefix)" = /opt/homebrew ] || exit 0
    /usr/bin/sudo -n -k /usr/bin/true >/dev/null 2>&1 || exit 0
    /usr/bin/git --version >/dev/null && /usr/bin/clang --version >/dev/null && printf 'ready\n'
    """#

    static let installScript = #"""
    set -eu
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    umask 077
    IFS= read -r COMET_VM_SUDO_PASSWORD
    export COMET_VM_SUDO_PASSWORD
    temporary=$(/usr/bin/mktemp -d /tmp/comet-tools.XXXXXX)
    trap '/bin/rm -rf "$temporary"; unset COMET_VM_SUDO_PASSWORD' EXIT
    /bin/cat > "$temporary/askpass" <<'ASKPASS'
    #!/bin/sh
    printf '%s\n' "$COMET_VM_SUDO_PASSWORD"
    ASKPASS
    /bin/chmod 700 "$temporary/askpass"
    export SUDO_ASKPASS="$temporary/askpass"
    [ "$(/usr/bin/id -un)" = comet ] || { printf '%s\n' 'VM tool setup must run as the comet guest account.' >&2; exit 1; }
    /usr/bin/sudo -A /bin/bash -s <<'POLICY'
    set -eu
    umask 077
    [ ! -L /private/etc/sudoers.d ] || { printf '%s\n' 'The guest sudo policy directory is an unexpected symbolic link.' >&2; exit 1; }
    /bin/mkdir -p /private/etc/sudoers.d
    policy=$(/usr/bin/mktemp /private/etc/sudoers.d/.comet.XXXXXX)
    trap '[ -z "$policy" ] || /bin/rm -f "$policy"' EXIT
    printf '%s\n' '# Comet macOS VM runner; grants workflows root access inside this guest.' 'comet ALL=(ALL) NOPASSWD: ALL' > "$policy"
    /usr/sbin/chown root:wheel "$policy"
    /bin/chmod 440 "$policy"
    /usr/sbin/visudo -cf "$policy"
    if [ -e /private/etc/sudoers.d/comet ] || [ -L /private/etc/sudoers.d/comet ]; then
        [ ! -L /private/etc/sudoers.d/comet ] && [ -f /private/etc/sudoers.d/comet ] &&
            /usr/bin/cmp -s "$policy" /private/etc/sudoers.d/comet ||
            { printf '%s\n' 'An unmanaged guest sudo policy already exists. Its contents were preserved.' >&2; exit 1; }
    fi
    /bin/mv -f "$policy" /private/etc/sudoers.d/comet
    policy=''
    POLICY
    /usr/bin/sudo -n -k /usr/bin/true
    /usr/bin/curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$temporary/install.sh"
    # Homebrew's root-owned CLT marker must be readable by its unprivileged update scan.
    (umask 022; NONINTERACTIVE=1 /bin/bash "$temporary/install.sh") || {
        installer_exit=$?
        developer=$(/usr/bin/xcode-select -p 2>/dev/null) || developer=''
        if [ -n "$developer" ] && [ -x "$developer/usr/bin/git" ] && [ -x "$developer/usr/bin/clang" ]; then
            exit "$installer_exit"
        fi
        printf 'The installer exited with status %s before Command Line Tools became available. Retrying once…\n' "$installer_exit" >&2
        (umask 022; NONINTERACTIVE=1 /bin/bash "$temporary/install.sh")
    }
    """#
}
