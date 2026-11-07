#!/bin/sh
# Portable bootstrap for the ArcheAge Proton timezone workaround.
# Package installation requires approval of the displayed command.
# Steam changes require separate approval in the existing Python installer.
set -u

REPOSITORY_URL='https://codeload.github.com/nemo-sec/archeage-proton-fix/tar.gz/refs/heads/main'
DEFAULT_DIRECTORY="${HOME:-}/.local/share/archeage-proton-fix-setup"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || exit 1
PYTHON_BIN=
WORK=
CHECK_WORK=
INSTALL_MISSING=0
BUILD_MISSING=0

usage() {
    cat <<'EOF'
Usage: setup.sh [--check [--install|--build]] [--directory PATH]

Without --check, download this repository (or reuse the checkout containing
this script), verify its checked-in artifacts, and start the guided installer.

  --check             Check installation and source-build requirements.
  --install           With --check, check only installation requirements.
  --build             With --check, check only source-build requirements.
  --directory PATH    Download destination (default: ~/.local/share/archeage-proton-fix-setup).
  --help              Show this help.

Checks and downloads never install packages. Missing system packages are only
offered during the default setup, after an exact command is displayed. The
installer itself runs as the normal user and retains its own Steam/game safety
checks.
EOF
}

fail() {
    printf 'setup: %s\n' "$*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

make_probe_directory() {
    # build.sh changes directory, so a relative TMPDIR must be resolved first.
    probe_parent=$(CDPATH= cd -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || return 1
    mktemp -d "$probe_parent/$1.XXXXXX"
}

mark_install_missing() {
    INSTALL_MISSING=1
    printf '  [missing] %s\n' "$1"
}

mark_build_missing() {
    BUILD_MISSING=1
    printf '  [missing] %s\n' "$1"
}

find_python() {
    if command_exists python3; then
        PYTHON_BIN=$(command -v python3)
    elif command_exists python; then
        PYTHON_BIN=$(command -v python)
    else
        PYTHON_BIN=
    fi
}

check_python() {
    find_python
    if [ -z "$PYTHON_BIN" ]; then
        mark_install_missing 'Python 3.9 or newer (python3)'
        return
    fi
    if "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
        printf '  [ok] Python 3.9 or newer (%s)\n' "$PYTHON_BIN"
    else
        mark_install_missing "Python 3.9 or newer ($PYTHON_BIN is too old or unusable)"
        return
    fi

    if "$PYTHON_BIN" -c 'import pefile' >/dev/null 2>&1; then
        printf '  [ok] Python pefile module\n'
        return
    fi
    venv_probe=$(make_probe_directory archeage-python-check 2>/dev/null) || {
        mark_install_missing 'Python pefile, or a writable temporary directory for venv/pip capability'
        return
    }
    CHECK_WORK=$venv_probe
    if "$PYTHON_BIN" -m venv "$venv_probe/venv" >/dev/null 2>&1 &&
       "$venv_probe/venv/bin/python" -m pip --version >/dev/null 2>&1; then
        printf '  [ok] Python can create a venv with pip (pefile will be fetched by install.py if needed)\n'
    else
        mark_install_missing 'Python pefile, or working python -m venv with pip'
    fi
    rm -rf -- "$venv_probe"
    CHECK_WORK=
}

check_gnu_cp() {
    if ! command_exists cp; then
        mark_install_missing 'GNU cp with --reflink=auto'
        return
    fi
    if ! cp --version 2>/dev/null | grep -q 'GNU coreutils'; then
        mark_install_missing 'GNU cp with --reflink=auto (the available cp is not GNU coreutils)'
        return
    fi
    cp_probe=$(make_probe_directory archeage-cp-check 2>/dev/null) || {
        mark_install_missing 'GNU cp --reflink=auto (temporary test directory unavailable)'
        return
    }
    CHECK_WORK=$cp_probe
    printf x >"$cp_probe/source"
    if cp --reflink=auto "$cp_probe/source" "$cp_probe/copy" >/dev/null 2>&1 &&
       test "$(cat "$cp_probe/copy" 2>/dev/null)" = x; then
        printf '  [ok] GNU cp --reflink=auto\n'
    else
        mark_install_missing 'GNU cp with working --reflink=auto capability'
    fi
    rm -rf -- "$cp_probe"
    CHECK_WORK=
}

check_sha256() {
    if ! command_exists sha256sum; then
        mark_install_missing 'sha256sum (GNU coreutils)'
        return
    fi
    if ! sha256sum --version 2>/dev/null | grep -q 'GNU coreutils'; then
        mark_install_missing 'GNU sha256sum (the available command is not GNU coreutils)'
        return
    fi
    sha_probe=$(make_probe_directory archeage-sha-check 2>/dev/null) || {
        mark_install_missing 'sha256sum test capability'
        return
    }
    CHECK_WORK=$sha_probe
    printf x >"$sha_probe/file"
    if sha256sum "$sha_probe/file" >/dev/null 2>&1; then
        printf '  [ok] sha256sum (GNU coreutils)\n'
    else
        mark_install_missing 'working sha256sum'
    fi
    rm -rf -- "$sha_probe"
    CHECK_WORK=
}

curl_capable() {
    command_exists curl && curl --help all 2>/dev/null | grep -q -- '--proto'
}

wget_capable() {
    command_exists wget && wget --help 2>/dev/null | grep -q -- '--https-only'
}

check_archive_tools() {
    if curl_capable; then
        printf '  [ok] HTTPS downloader: curl with HTTPS-only redirect controls\n'
    elif wget_capable; then
        printf '  [ok] HTTPS downloader: wget with --https-only\n'
    else
        mark_install_missing 'curl with --proto, or GNU wget with --https-only (BusyBox wget is not accepted)'
    fi
    if command_exists tar && tar --version 2>/dev/null | grep -q 'GNU tar'; then
        printf '  [ok] GNU tar\n'
    else
        mark_install_missing 'GNU tar'
    fi
    if command_exists gzip && gzip --version 2>/dev/null | grep -Eq '^gzip [0-9]'; then
        printf '  [ok] GNU gzip\n'
    else
        mark_install_missing 'GNU gzip'
    fi
}

check_install_group() {
    include_archive=${1:-1}
    INSTALL_MISSING=0
    printf 'Installation requirements\n'
    check_python
    check_gnu_cp
    check_sha256
    if [ "$include_archive" -eq 1 ]; then
        check_archive_tools
    else
        printf '  [ok] archive downloader not needed when reusing this local checkout\n'
    fi
    if [ "$INSTALL_MISSING" -eq 0 ]; then
        printf 'Installation result: PASS\n'
    else
        printf 'Installation result: FAIL\n'
    fi
}

check_build_tool() {
    name=$1
    if command_exists "$name"; then
        printf '  [ok] %s\n' "$name"
    else
        mark_build_missing "$name (unversioned command required by build.sh)"
    fi
}

windows_smoke() {
    smoke_dir=$1
    printf 'LIBRARY kernel32.dll\nEXPORTS\nExitProcess\n' >"$smoke_dir/kernel32.def"
    cat >"$smoke_dir/smoke.c" <<'EOF'
__declspec(dllimport) void ExitProcess(unsigned int);
void mainCRTStartup(void) { ExitProcess(0); }
EOF
    llvm-dlltool -m i386:x86-64 -d "$smoke_dir/kernel32.def" -l "$smoke_dir/kernel32.lib" >/dev/null 2>&1 || return 1
    clang --target=x86_64-pc-windows-msvc -c -ffreestanding -fno-stack-protector \
        "$smoke_dir/smoke.c" -o "$smoke_dir/smoke.obj" >/dev/null 2>&1 || return 1
    lld-link /timestamp:0 /dll /noentry /nodefaultlib \
        /out:"$smoke_dir/smoke.dll" "$smoke_dir/smoke.obj" "$smoke_dir/kernel32.lib" >/dev/null 2>&1 || return 1
    lld-link /timestamp:0 /entry:mainCRTStartup /subsystem:console /nodefaultlib \
        /out:"$smoke_dir/smoke.exe" "$smoke_dir/smoke.obj" "$smoke_dir/kernel32.lib" >/dev/null 2>&1
}

check_build_group() {
    BUILD_MISSING=0
    printf 'Source build requirements\n'
    check_build_tool bash
    check_build_tool clang
    check_build_tool llvm-dlltool
    check_build_tool lld-link
    for coreutil in dirname mkdir realpath; do
        if command_exists "$coreutil" && "$coreutil" --version 2>/dev/null | grep -q 'GNU coreutils'; then
            printf '  [ok] GNU coreutils %s\n' "$coreutil"
        else
            mark_build_missing "GNU coreutils $coreutil (used by build.sh)"
        fi
    done
    if [ "$BUILD_MISSING" -eq 0 ]; then
        build_probe=$(make_probe_directory archeage-build-check 2>/dev/null) || {
            mark_build_missing 'temporary directory for Windows compile/import-library/link smoke test'
        }
        if [ "$BUILD_MISSING" -eq 0 ]; then
            CHECK_WORK=$build_probe
            smoke_status=0
            if [ -f "$SCRIPT_DIR/build.sh" ]; then
                (cd "$SCRIPT_DIR" && bash build.sh "$build_probe/out") >/dev/null 2>&1 &&
                    test -s "$build_probe/out/tzcompat.dll" &&
                    test -s "$build_probe/out/probe.exe" &&
                    test -s "$build_probe/out/kernel32.lib" || smoke_status=$?
            else
                windows_smoke "$build_probe" || smoke_status=$?
            fi
            if [ "$smoke_status" -eq 0 ]; then
                printf '  [ok] Windows compile + import-library + link smoke test\n'
            else
                mark_build_missing 'Windows compile + import-library + link smoke test (clang/llvm-dlltool/lld-link failed)'
            fi
            rm -rf -- "$build_probe"
            CHECK_WORK=
        fi
    else
        printf '  [skip] Windows compile + import-library + link smoke test (tool missing)\n'
    fi
    if [ "$BUILD_MISSING" -eq 0 ]; then
        printf 'Source build result: PASS\n'
    else
        printf 'Source build result: FAIL\n'
    fi
}

run_checks() {
    selected=${1:-all}
    if [ "$selected" = install ] || [ "$selected" = all ]; then
        check_install_group 1
    fi
    if [ "$selected" = build ] || [ "$selected" = all ]; then
        check_build_group
    fi
    if [ "$selected" = install ]; then
        [ "$INSTALL_MISSING" -eq 0 ] || show_package_command install >/dev/null
        [ "$INSTALL_MISSING" -eq 0 ]
    elif [ "$selected" = build ]; then
        [ "$BUILD_MISSING" -eq 0 ] || show_package_command build >/dev/null
        [ "$BUILD_MISSING" -eq 0 ]
    else
        [ "$INSTALL_MISSING" -eq 0 ] || show_package_command install >/dev/null
        [ "$BUILD_MISSING" -eq 0 ] || show_package_command build >/dev/null
        [ "$INSTALL_MISSING" -eq 0 ] && [ "$BUILD_MISSING" -eq 0 ]
    fi
}

package_manager() {
    # Fedora Silverblue/Bazzite
    if [ -d /run/ostree-booted ]; then
        printf 'rpm-ostree'
        return 0
    fi

    # Installed foreign package managers must not select root commands for this OS.
    identities=$(
        if [ -r /etc/os-release ]; then
            . /etc/os-release
            printf '%s %s' "${ID:-}" "${ID_LIKE:-}"
        fi
    )

    native_manager=
    for family in $identities; do
        case "$family" in
            debian|ubuntu) native_manager=apt-get ;;
            fedora|rhel|centos|rocky|almalinux) native_manager=dnf ;;
            arch|cachyos|manjaro|endeavouros) native_manager=pacman ;;
            opensuse*|suse|sles) native_manager=zypper ;;
            alpine) native_manager=apk ;;
            *) continue ;;
        esac
        break
    done
    [ -n "$native_manager" ] && command_exists "$native_manager" || return 1
    printf '%s' "$native_manager"
}

show_package_command() {
    group=$1
    manager=$(package_manager 2>/dev/null || true)
    [ -n "$manager" ] || {
        printf 'No supported native distro/package-manager mapping found. Install the missing requirements manually.\n' >&2
        return 1
    }
    case "$manager" in
        zypper)
            if [ "$group" = build ]; then
                printf 'openSUSE: install Bash, GNU coreutils and the matching clang/llvm/lld toolchain manually; expose clang, llvm-dlltool and lld-link on PATH.\n' >&2
            else
                printf 'openSUSE: install Python >=3.9 with venv/pip, GNU coreutils and any listed download tools manually. Leap 15.6 defaults to older Python; do not replace the system interpreter.\n' >&2
            fi
            return 1 ;;
        apk)
            if [ "$group" = build ]; then
                printf 'Alpine: install Bash, GNU coreutils and matching versioned clang/llvm/lld packages manually; expose clang, llvm-dlltool and lld-link on PATH.\n' >&2
            else
                printf 'Alpine: install Python >=3.9 with venv/pip, GNU coreutils and any listed download tools manually. Native Steam compatibility on musl is not validated.\n' >&2
            fi
            return 1 ;;
    esac
    case "$manager:$group" in
        apt-get:install) command_text='sudo apt-get install python3 python3-venv python3-pip coreutils curl tar gzip' ;;
        dnf:install) command_text='sudo dnf install python3 python3-pip coreutils curl tar gzip' ;;
        pacman:install) command_text='sudo pacman -S --needed python python-pip coreutils curl tar gzip' ;;
        apt-get:build) command_text='sudo apt-get install bash coreutils clang llvm lld' ;;
        dnf:build) command_text='sudo dnf install bash coreutils clang llvm lld' ;;
        pacman:build) command_text='sudo pacman -S --needed bash coreutils clang llvm lld' ;;
        rpm-ostree:install) command_text='rpm-ostree install python3 python3-pip coreutils curl tar gzip && echo "Reboot to apply rpm-ostree."' ;;
        *) return 1 ;;
    esac
    printf 'Suggested command for %s (package availability depends on your distro):\n' "$manager" >&2
    printf '  %s\n' "$command_text" >&2
    printf '%s\n' "$command_text"
}

run_package_command() {
    group=$1
    manager=$(package_manager 2>/dev/null || true)
    [ -n "$manager" ] || return 1
    case "$manager:$group" in
        apt-get:install) sudo apt-get install python3 python3-venv python3-pip coreutils curl tar gzip ;;
        dnf:install) sudo dnf install python3 python3-pip coreutils curl tar gzip ;;
        pacman:install) sudo pacman -S --needed python python-pip coreutils curl tar gzip ;;
        apt-get:build) sudo apt-get install bash coreutils clang llvm lld ;;
        dnf:build) sudo dnf install bash coreutils clang llvm lld ;;
        pacman:build) sudo pacman -S --needed bash coreutils clang llvm lld ;;
        *) return 1 ;;
    esac
}

offer_install_packages() {
    [ "$INSTALL_MISSING" -ne 0 ] || return 0
    current_uid=$(id -u 2>/dev/null) || fail 'cannot determine the current user; no package command will run'
    if [ "$current_uid" -eq 0 ]; then
        fail 'run as your normal user; setup will not run package installation as root'
    fi
    show_package_command install >/dev/null || return 1
    printf 'The installation check found missing requirements. No package command has run.\n' >&2
    printf 'Run this exact command with sudo? [y/N] ' >&2
    if ! read answer; then
        printf '\nCancelled.\n' >&2
        return 1
    fi
    case "$answer" in
        y|Y|yes|YES|Yes) ;;
        *) printf 'Cancelled. No files changed.\n' >&2; return 1 ;;
    esac
    # Use the selected manager directly rather than eval'ing displayed text.
    run_package_command install || return 1
    return 0
}

verify_source() {
    source=$1
    [ -f "$source/install.py" ] || { printf 'Downloaded source is missing install.py.\n' >&2; return 1; }
    [ -f "$source/SHA256SUMS" ] || { printf 'Downloaded source is missing SHA256SUMS.\n' >&2; return 1; }
    [ -f "$source/bin/tzcompat.dll" ] && [ -f "$source/bin/probe.exe" ] || {
        printf 'Downloaded source is missing checked-in bin artifacts.\n' >&2
        return 1
    }
    manifest_count=0
    manifest_ok=1
    while IFS=' ' read -r digest name extra; do
        manifest_count=$((manifest_count + 1))
        case "$manifest_count:$name:$extra" in
            1:bin/tzcompat.dll:) ;;
            2:bin/probe.exe:) ;;
            *) manifest_ok=0 ;;
        esac
    done <"$source/SHA256SUMS"
    [ "$manifest_count" -eq 2 ] && [ "$manifest_ok" -eq 1 ] || {
        printf 'Checksum manifest contains unexpected paths.\n' >&2
        return 1
    }
    printf 'Verifying checked-in artifact checksums...\n' >&2
    (cd "$source" && sha256sum -c SHA256SUMS) || {
        printf 'Checksum verification failed. Nothing was handed to install.py.\n' >&2
        return 1
    }
}

archive_safe_to_extract() {
    archive=$1
    members=$2
    verbose=$3
    tar -tzf "$archive" >"$members" 2>/dev/null || return 1
    tar -tvzf "$archive" >"$verbose" 2>/dev/null || return 1
    top=
    while IFS= read -r member; do
        case "$member" in
            ''|/*|../*|*/../*|*/..|./*|*/./*) return 1 ;;
        esac
        case "$member" in
            */*) prefix=${member%%/*} ;;
            *) return 1 ;;
        esac
        if [ -z "$top" ]; then top=$prefix
        elif [ "$prefix" != "$top" ]; then return 1
        fi
    done <"$members"
    [ -n "$top" ] || return 1
    while IFS= read -r line; do
        type=${line%${line#?}}
        case "$type" in
            -|d) ;;
            *) return 1 ;;
        esac
    done <"$verbose"
    printf '%s\n' "$top"
}

run_installer() {
    source=$1
    printf 'Starting the existing guided installer. It will ask for its own Steam/prefix confirmations.\n' >&2
    (cd "$source" && "$PYTHON_BIN" install.py)
}

download_and_handoff() {
    destination=$1
    parent=$(dirname -- "$destination")
    base=$(basename -- "$destination")
    [ -n "$base" ] && [ "$base" != . ] && [ "$base" != .. ] || fail 'invalid destination'
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "destination already exists: $destination"
    mkdir -p -- "$parent" || fail "cannot create destination parent: $parent"
    WORK=$(mktemp -d "$parent/.archeage-setup.XXXXXX") || fail 'cannot create a private temporary staging directory'
    archive=$WORK/repository.tar.gz
    members=$WORK/members
    verbose=$WORK/verbose
    extract=$WORK/extract
    mkdir "$extract" || fail 'cannot create extraction directory'
    printf 'Downloading repository archive over HTTPS...\n' >&2
    if curl_capable; then
        curl --fail --location --proto '=https' --proto-redir '=https' --silent --show-error --output "$archive" "$REPOSITORY_URL" || fail 'download failed'
    elif wget_capable; then
        wget --https-only --no-verbose --output-document="$archive" "$REPOSITORY_URL" || fail 'download failed'
    else
        fail 'no HTTPS-capable curl or wget is available'
    fi
    top=$(archive_safe_to_extract "$archive" "$members" "$verbose") || fail 'archive has unsafe paths or unsupported links; nothing was extracted'
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$extract" || fail 'archive extraction failed'
    find "$extract" -type l -print -quit | grep -q . && fail 'archive extraction produced a symlink; refusing trust-boundary risk'
    source=$extract/$top
    [ -d "$source" ] || fail 'archive did not contain one top-level source directory'
    verify_source "$source" || fail 'downloaded source failed validation'
    printf 'Moving the verified checkout into %s\n' "$destination" >&2
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "destination appeared during download: $destination"
    mv -T --no-clobber -- "$source" "$destination" || fail 'could not install the verified checkout'
    [ ! -e "$source" ] && [ -d "$destination" ] || fail "destination appeared or publish did not complete: $destination"
    run_installer "$destination"
    return "$?"
}

check_local_source() {
    [ -f "$SCRIPT_DIR/install.py" ] && [ -f "$SCRIPT_DIR/SHA256SUMS" ] && [ -d "$SCRIPT_DIR/bin" ]
}

main() {
    check=0
    selected=all
    destination=$DEFAULT_DIRECTORY
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) check=1 ;;
            --install)
                [ "$selected" = all ] || fail '--install and --build cannot be combined'
                selected=install ;;
            --build)
                [ "$selected" = all ] || fail '--install and --build cannot be combined'
                selected=build ;;
            --directory)
                shift
                [ "$#" -gt 0 ] || fail '--directory requires PATH'
                destination=$1 ;;
            --directory=*) destination=${1#--directory=} ;;
            --help|-h) usage; exit 0 ;;
            *) fail "unknown option: $1 (try --help)" ;;
        esac
        shift
    done
    [ "$selected" = all ] || [ "$check" -eq 1 ] || fail '--install/--build are only valid with --check'

    if [ "$check" -eq 1 ]; then
        run_checks "$selected"
        exit $?
    fi
    current_uid=$(id -u 2>/dev/null) || fail 'cannot determine the current user; run as your normal Steam user'
    [ "$current_uid" -ne 0 ] || fail 'run as your normal user, without sudo'
    if check_local_source; then
        printf 'Using the local checkout; no repository download is needed.\n' >&2
        check_install_group 0
        [ "$INSTALL_MISSING" -eq 0 ] || {
            offer_install_packages || fail 'install requirements are still missing'
            check_install_group 0
            [ "$INSTALL_MISSING" -eq 0 ] || fail 'install requirements remain missing'
        }
        verify_source "$SCRIPT_DIR" || fail 'local checkout failed checksum validation'
        run_installer "$SCRIPT_DIR"
    else
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "destination already exists: $destination"
        check_install_group 1
        [ "$INSTALL_MISSING" -eq 0 ] || {
            offer_install_packages || fail 'install requirements are still missing'
            check_install_group 1
            [ "$INSTALL_MISSING" -eq 0 ] || fail 'install requirements remain missing'
        }
        download_and_handoff "$destination"
    fi
}

cleanup() {
    status=$?
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf -- "$WORK"
    fi
    if [ -n "$CHECK_WORK" ] && [ -d "$CHECK_WORK" ]; then
        rm -rf -- "$CHECK_WORK"
    fi
    exit "$status"
}
trap cleanup 0
trap 'exit 130' INT TERM HUP
main "$@"
