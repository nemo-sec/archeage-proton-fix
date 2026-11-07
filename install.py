#!/usr/bin/env python3
"""Install the ArcheAge timezone workaround into a private Proton copy."""
import argparse
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DLL_PATH = Path('files/lib/wine/x86_64-windows/kernel32.dll')
TOOL_NAME = 'Proton-ArcheAge-TZ-Fix'


def ask(prompt):
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise ValueError('Run in a terminal, or supply --yes and explicit path flags. See --help.')
    print(prompt, end=' ', file=sys.stderr, flush=True)
    return input().strip()


def choose(label, paths, explicit, yes):
    if explicit:
        return explicit.expanduser().resolve()
    paths = list(dict.fromkeys(p.resolve() for p in paths))
    if len(paths) == 1:
        return paths[0]
    if not paths:
        raise ValueError(f'Could not find {label}. Supply its path using --help.')
    print(f'Choose {label}:', file=sys.stderr)
    for index, path in enumerate(paths, 1):
        print(f'  {index}. {path}', file=sys.stderr)
    if yes:
        raise ValueError(f'Multiple choices for {label}; supply an explicit path flag.')
    while True:
        answer = ask('Enter a number (Ctrl+C cancels):')
        if answer.isdigit() and 1 <= int(answer) <= len(paths):
            return paths[int(answer) - 1]
        print('Please enter one of the listed numbers.', file=sys.stderr)


def libraries(steam):
    result = [steam]
    index = steam / 'steamapps/libraryfolders.vdf'
    if index.is_file():
        for match in re.finditer(r'^\s*"path"\s*"((?:[^"\\]|\\.)*)"', index.read_text(), re.MULTILINE):
            value = re.sub(r'\\(["\\])', r'\1', match[1])
            result.append(Path(value).expanduser().resolve())
    return list(dict.fromkeys(result))


def verify_artifacts():
    expected = {}
    for line in (ROOT / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        expected[name] = digest
    if set(expected) != {'bin/tzcompat.dll', 'bin/probe.exe'}:
        raise ValueError('Unexpected SHA256SUMS entries. Download a fresh copy of this repository.')
    for name, digest in expected.items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f'Checksum mismatch: {name}. Download a fresh copy before installing.')


def require_idle():
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            name = (process / 'comm').read_text().strip().lower()
            busy = name in {'steam', 'steamwebhelper', 'archeagechronic'}
            if not busy:
                # Unreal can rename the main thread to GameThread; comm alone is insufficient.
                arguments = (process / 'cmdline').read_bytes().split(b'\0')
                busy = any(arg.replace(b'\\', b'/').rsplit(b'/', 1)[-1].lower() == b'archeagechronicles.exe'
                           for arg in arguments)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if busy:
            raise ValueError('Fully exit the game and Steam (Steam menu > Exit), then run this again.')


def validate_paths(steam, library, proton):
    #if '.var/app/com.valvesoftware.Steam' in str(steam):
    #   raise ValueError('Flatpak Steam is not supported by this installer. No files changed.')
    if not (steam / 'steamapps').is_dir():
        raise ValueError(f'Not a Steam installation: {steam}')
    app = library / 'steamapps/compatdata/3218230'
    prefix = app / 'pfx'
    system32 = prefix / 'drive_c/windows/system32'
    if not system32.is_dir():
        raise ValueError('Game prefix missing. Launch ArcheAge once, exit it and Steam, then try again.')
    shim = system32 / 'tzcompat.dll'
    custom = steam / 'compatibilitytools.d' / TOOL_NAME
    backup = app.with_name(app.name + '.before-tz-fix')
    if not system32.resolve().is_relative_to(app.resolve()):
        raise ValueError('External prefix/system32 symlinks are unsupported. Use the manual instructions.')
    if not (proton / 'proton').is_file() or not (proton / DLL_PATH).is_file():
        raise ValueError(f'Unsupported Proton layout: {proton}. See the advanced instructions.')
    for path in (custom, backup, shim):
        if path.exists() or path.is_symlink():
            raise ValueError(f'Already exists: {path}\nNo overwrite attempted. See README troubleshooting.')
    return app, shim, custom, backup


def ensure_dependency(steam, library, proton):
    if importlib.util.find_spec('pefile'):
        return
    environment = ROOT / '.venv'
    python = environment / 'bin/python'
    if Path(sys.prefix).resolve() == environment.resolve():
        raise ValueError('pefile is missing from .venv. Run .venv/bin/python -m pip install -r requirements.txt')
    print('Preparing a local Python helper in .venv (one PyPI download).', file=sys.stderr)
    subprocess.run([sys.executable, '-m', 'venv', str(environment)], check=True)
    subprocess.run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check',
                    '-r', str(ROOT / 'requirements.txt')], check=True)
    os.execv(str(python), [str(python), str(ROOT / 'install.py'), '--yes',
                         '--steam-root', str(steam), '--library', str(library), '--proton', str(proton)])


def install(steam, library, proton):
    from add_forwarder import patched_bytes

    app, shim, custom, backup = validate_paths(steam, library, proton)
    original = (proton / DLL_PATH).read_bytes()
    patched = patched_bytes(original)  # Refuse incompatible DLLs before any installation writes.
    parent = custom.parent
    parent.mkdir(parents=True, exist_ok=True)
    lock = parent / '.archeage-tz-install.lock'
    stage = None
    backup_stage = None
    created_shim = False
    complete = False
    with lock.open('x'):
        try:
            require_idle()
            validate_paths(steam, library, proton)
            stage = Path(tempfile.mkdtemp(prefix='.archeage-tz-', dir=parent))
            print('Copying Proton. This can take a few minutes...', file=sys.stderr)
            subprocess.run(['cp', '-a', '--reflink=auto', str(proton) + '/.', str(stage)], check=True)
            target = stage / DLL_PATH
            config = stage / 'compatibilitytool.vdf'
            if target.is_symlink() or not target.resolve().is_relative_to(stage):
                raise ValueError('Private DLL points outside the copied runtime. Refusing to patch it.')
            if config.is_symlink():
                raise ValueError('Symlinked compatibility configuration is unsupported.')
            if target.read_bytes() != original:
                raise ValueError('Source DLL changed during the copy. Stop and try again.')
            target.chmod(target.stat().st_mode | 0o200)
            target.write_bytes(patched)
            target.chmod(target.stat().st_mode & ~0o200)
            shutil.copyfile(ROOT / 'compatibilitytool.vdf', config)

            print('Backing up the game prefix. Your saves/settings are not replaced.', file=sys.stderr)
            backup_stage = Path(tempfile.mkdtemp(prefix='.3218230-backup-', dir=app.parent))
            subprocess.run(['cp', '-a', '--reflink=auto', str(app) + '/.', str(backup_stage)], check=True)
            backup_stage.rename(backup)
            backup_stage = None
            (stage / 'archeage-tz-install.json').write_text(json.dumps({
                'base_proton': str(proton), 'prefix_backup': str(backup), 'shim': str(shim),
                'original_kernel32_sha256': hashlib.sha256(original).hexdigest(),
                'patched_kernel32_sha256': hashlib.sha256(patched).hexdigest(),
            }, indent=2) + '\n')
            require_idle()
            with shim.open('xb') as destination:
                created_shim = True
                destination.write((ROOT / 'bin/tzcompat.dll').read_bytes())
            stage.rename(custom)
            stage = None
            complete = True
        finally:
            if created_shim and not complete:
                shim.unlink(missing_ok=True)
            if stage is not None:
                shutil.rmtree(stage)
            if backup_stage is not None:
                shutil.rmtree(backup_stage)
            lock.unlink()
    return custom, backup


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'Interactive: python3 install.py\n'
        'Automation: supply --yes --steam-root PATH --library PATH --proton PATH.\n'
        'No root/sudo, game downloads, or shared-runtime edits. See README.md.'),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--steam-root', type=Path, help='Steam installation directory')
    parser.add_argument('--library', type=Path, help='Steam library containing ArcheAge')
    parser.add_argument('--proton', type=Path, help='Unmodified base Proton directory')
    parser.add_argument('--yes', action='store_true', help='Approve displayed installation and local helper download')
    parser.add_argument('--dry-run', action='store_true', help='Show paths and plan without downloading or changing files')
    args = parser.parse_args()
    if sys.platform != 'linux' or platform.machine().lower() not in {'x86_64', 'amd64'}:
        raise ValueError('This installer supports Linux x86-64 only.')
    if os.geteuid() == 0:
        raise ValueError('Run as your normal Steam user, without sudo.')
    verify_artifacts()
    home = Path.home()
    roots = [p for p in (home / '.local/share/Steam', home / '.steam/steam', home / '.var/app/com.valvesoftware.Steam/data/Steam') if (p / 'steamapps').is_dir()]
    steam = choose('Steam installation (--steam-root)', roots, args.steam_root, args.yes)
    all_libraries = libraries(steam)
    installed = [p for p in all_libraries if (p / 'steamapps/compatdata/3218230/pfx').is_dir()]
    library = choose('game library (--library)', installed, args.library, args.yes)
    locations = [steam / 'compatibilitytools.d', Path('/usr/share/steam/compatibilitytools.d')]
    locations += [p / 'steamapps/common' for p in all_libraries]
    runtimes = []
    for location in locations:
        if location.is_dir():
            runtimes.extend(p for p in sorted(location.iterdir())
                            if p.name != TOOL_NAME and (p / 'proton').is_file() and (p / DLL_PATH).is_file())
    proton = choose('base Proton (--proton)', runtimes, args.proton, args.yes)
    _, _, custom, backup = validate_paths(steam, library, proton)
    print(f'\nBase Proton: {proton}\nPrivate copy: {custom}\nPrefix backup: {backup}', file=sys.stderr)
    print('Shared Proton and game binaries stay unchanged. Anti-cheat compatibility is not guaranteed.', file=sys.stderr)
    if args.dry_run:
        print('Dry run: no files changed. DLL compatibility will be checked during installation.')
        return 0
    require_idle()
    if not args.yes and ask('Install? A local Python helper may be downloaded. [y/N]').lower() not in {'y', 'yes'}:
        print('Cancelled. No files changed.')
        return 0
    ensure_dependency(steam, library, proton)
    custom, backup = install(steam, library, proton)
    print('\nInstalled. Next steps in Steam:\n'
          '1. Start Steam.\n'
          '2. ArcheAge Chronicles > Properties > Compatibility.\n'
          '3. Enable the override and select Proton ArcheAge TZ Fix (experimental).\n'
          '4. Launch the game. First-time shader compilation may take a while.\n'
          '\nTo undo: select your original Proton in Compatibility.\n'
          f'Backup: {backup}\nPrivate runtime: {custom}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nCancelled. Any completed prefix backup is retained.', file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'\nInstallation stopped: {error}\nSee README.md > Troubleshooting before retrying.', file=sys.stderr)
        sys.exit(1)
