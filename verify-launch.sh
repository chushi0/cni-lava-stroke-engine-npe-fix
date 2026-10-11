#!/usr/bin/env bash
#
# Launches the Minecraft client of the configured instance once (up to the title screen) so that the
# fix can be verified from the log, then leaves it running for a short while before killing it.
#
# It only proves the interesting part of the fix though - the crash happened purely because
# PartialModel#get() returned null - so the lines we look for are:
#
#   [CNI Lava Stroke Engine Fix] Registered the Lava Stroke Engine partial models ...
#   [CNI Lava Stroke Engine Fix] Post-bake state of the Lava Stroke Engine models: rod=OK, flywheel=OK
#
set -euo pipefail

MC_DIR="${MC_DIR:-D:/program/Minecraft/.minecraft}"
VERSION_NAME="${VERSION_NAME:-1.21.1-NeoForge_21.1.244}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_DIR="$MC_DIR/versions/$VERSION_NAME"
BUILD_DIR="$PROJECT_DIR/build"
LOG="$GAME_DIR/logs/latest.log"
STDOUT_LOG="$BUILD_DIR/launch-stdout.log"
PID_FILE="$BUILD_DIR/launch.pid"

mkdir -p "$BUILD_DIR"

if [ ! -f "$GAME_DIR/$VERSION_NAME.json" ]; then
    echo "ERROR: version json not found in $GAME_DIR"
    exit 1
fi

PYTHON="${PYTHON:-$(command -v python || command -v python3 || true)}"
[ -n "$PYTHON" ] || { echo "ERROR: python not found"; exit 1; }

# extra JVM properties, e.g. EXTRA_JVM="-Dmixin.debug.export=true" to dump the transformed classes
EXTRA_JVM="${EXTRA_JVM:-}"

echo "==> starting the client of $VERSION_NAME (game dir: $GAME_DIR)"
echo "==> game stdout goes to $STDOUT_LOG"

"$PYTHON" - "$MC_DIR" "$VERSION_NAME" "$GAME_DIR" "$STDOUT_LOG" "$PID_FILE" "$EXTRA_JVM" <<'PYEOF'
import glob, json, os, subprocess, sys, uuid

mc_dir, version_name, game_dir, stdout_log, pid_file, extra_jvm = sys.argv[1:7]
version_json = os.path.join(game_dir, version_name + '.json')
library_dir = os.path.join(mc_dir, 'libraries')


def win(path):
    return os.path.abspath(path).replace('\\', '/')


def library_paths():
    paths = []
    with open(version_json, encoding='utf-8') as handle:
        version = json.load(handle)
    for lib in version.get('libraries', []):
        path = lib.get('downloads', {}).get('artifact', {}).get('path')
        if not path and lib.get('name'):
            parts = lib['name'].split(':')
            if len(parts) >= 3:
                classifier = '-' + parts[3] if len(parts) > 3 else ''
                path = '{}/{}/{}/{}-{}{}.jar'.format(parts[0].replace('.', '/'), parts[1], parts[2],
                                                     parts[1], parts[2], classifier)
        if path:
            full = os.path.join(library_dir, path.replace('/', os.sep))
            if os.path.isfile(full):
                paths.append(win(full))
    # NOTE: only the version json's libraries belong on the classpath. The patched Minecraft /
    # NeoForge jars are pulled in through the module path (see "--add-modules ALL-MODULE-PATH"),
    # and having them on the classpath as well makes the module layer fail to resolve.
    # the json repeats a few artifacts (e.g. gson) - the bootstraplauncher rejects duplicates
    seen = set()
    unique = []
    for path in paths:
        if path not in seen:
            seen.add(path)
            unique.append(path)
    return unique


def expand(value, variables):
    if isinstance(value, list):
        return [expand(v, variables) for v in value]
    if not isinstance(value, str):
        return value
    for key, replacement in variables.items():
        value = value.replace('${' + key + '}', replacement)
    return value


with open(version_json, encoding='utf-8') as handle:
    version = json.load(handle)

arguments = version.get('arguments', {})
variables = {
    'natives_directory': win(os.path.join(game_dir, version_name + '-natives')),
    'library_directory': win(library_dir),
    'classpath_separator': ';',
    'classpath': ';'.join(library_paths()),
    'version_name': version_name,
    'launcher_name': 'verify-launch',
    'launcher_version': '1',
    'auth_player_name': 'VerifyLaunch',
    'auth_uuid': str(uuid.uuid4()),
    'auth_access_token': '0',
    'clientid': '0',
    'auth_xuid': '0',
    'user_type': 'legacy',
    'version_type': 'release',
    'game_directory': win(game_dir),
    'assets_root': win(os.path.join(mc_dir, 'assets')),
    'assets_index_name': version.get('assetIndex', {}).get('id', '17'),
}

jvm = []
for entry in arguments.get('jvm', []):
    if isinstance(entry, str):
        jvm.append(expand(entry, variables))
    elif isinstance(entry, dict) and entry.get('rules'):
        # only keep entries that are unconditional for this platform; skip OS/feature specific ones
        continue

game = []
for entry in arguments.get('game', []):
    if isinstance(entry, str):
        game.append(expand(entry, variables))
    elif isinstance(entry, dict):
        # feature/OS specific entries (demo mode, custom resolution, quick play) are skipped
        continue

java = os.path.join(os.environ.get('JAVA_HOME', ''), 'bin', 'java' + ('.exe' if os.name == 'nt' else ''))
if not os.path.isfile(java):
    java = 'java'

command = [java, '-Xmx4G'] + jvm + [version['mainClass']] + game
print('    java: {}'.format(java))
print('    main: {}'.format(version['mainClass']))

with open(stdout_log, 'wb') as out:
    process = subprocess.Popen(command, cwd=game_dir, stdout=out, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, creationflags=0x00000008 if os.name == 'nt' else 0)
with open(pid_file, 'w', encoding='utf-8') as handle:
    handle.write(str(process.pid))
print('    pid: {}'.format(process.pid))
PYEOF
