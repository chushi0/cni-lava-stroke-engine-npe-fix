#!/usr/bin/env bash
#
# Builds the "CNI Lava Stroke Engine NPE Fix" mod with plain javac + jar.
#
# No Gradle / NeoGradle bootstrap is required: NeoForge 1.21.1 runs Mojang-mapped classes, and every
# jar the mod compiles against is already installed in the Minecraft instance.
#
# Usage:
#   ./build.sh              build ./build/libs/cni_lavastrokefix-1.0.0.jar
#   ./build.sh --install    build and copy the jar into the instance's mods folder
#
# Environment overrides: MC_DIR, VERSION_NAME, INSTALL_DIR, JAVA_HOME, JAVAC, JAR_TOOL, PYTHON
#
set -euo pipefail

MC_DIR="${MC_DIR:-D:/program/Minecraft/.minecraft}"
VERSION_NAME="${VERSION_NAME:-1.21.1-NeoForge_21.1.244}"
INSTALL_DIR="${INSTALL_DIR:-$MC_DIR/versions/$VERSION_NAME/mods}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_DIR="$MC_DIR/versions/$VERSION_NAME"
VERSION_JSON="$GAME_DIR/$VERSION_NAME.json"
BUILD_DIR="$PROJECT_DIR/build"
CLASSES_DIR="$BUILD_DIR/classes"
LIBS_DIR="$BUILD_DIR/libs"
DEPS_DIR="$BUILD_DIR/deps"
MOD_VERSION="1.0.0"
JAR_NAME="cni_lavastrokefix-$MOD_VERSION"
JAR_FILE="$LIBS_DIR/$JAR_NAME.jar"

JAVAC="${JAVAC:-$(command -v javac || true)}"
JAR_TOOL="${JAR_TOOL:-$(command -v jar || true)}"
PYTHON="${PYTHON:-$(command -v python || command -v python3 || true)}"

if [ -z "$JAVAC" ]; then echo "ERROR: javac not found (set JAVA_HOME or JAVAC)"; exit 1; fi
if [ -z "$JAR_TOOL" ]; then echo "ERROR: jar not found (set JAVA_HOME or JAR_TOOL)"; exit 1; fi
if [ -z "$PYTHON" ]; then echo "ERROR: python not found (set PYTHON)"; exit 1; fi
if [ ! -f "$VERSION_JSON" ]; then echo "ERROR: version json not found: $VERSION_JSON"; exit 1; fi

echo "==> compiler: $("$JAVAC" -version 2>&1)"
echo "==> instance: $GAME_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$CLASSES_DIR" "$LIBS_DIR" "$DEPS_DIR"

# ---------------------------------------------------------------------------
# 1) Collect the compilation classpath straight from the instance:
#      - every library listed in the version json
#      - the NeoForge jars (the *-client.jar holds the patched Minecraft classes)
#      - the vanilla client jar
#      - every mod jar plus the libraries nested inside them (jar-in-jar)
#    Mod jars are copied into build/deps with ASCII names so that javac never has
#    to deal with spaces, brackets or CJK characters in the classpath.
# ---------------------------------------------------------------------------
"$PYTHON" - "$MC_DIR" "$GAME_DIR" "$VERSION_JSON" "$DEPS_DIR" "$BUILD_DIR/cp.args" <<'PYEOF'
import glob, json, os, re, shutil, sys, zipfile

mc_dir, game_dir, version_json, deps_dir, cp_file = sys.argv[1:6]


def win(path):
    """Absolute path with forward slashes (safe inside a javac @argfile)."""
    return os.path.abspath(path).replace('\\', '/')


def ascii_name(text):
    cleaned = re.sub(r'[^0-9A-Za-z._-]+', '_', text).strip('_')
    return cleaned or 'entry'


libs = []
skipped = 0

# --- libraries declared in the version json -------------------------------
with open(version_json, encoding='utf-8') as handle:
    version = json.load(handle)

for lib in version.get('libraries', []):
    path = lib.get('downloads', {}).get('artifact', {}).get('path')
    if not path and lib.get('name'):
        parts = lib['name'].split(':')
        if len(parts) >= 3:
            group, artifact, ver = parts[0], parts[1], parts[2]
            classifier = '-' + parts[3] if len(parts) > 3 else ''
            path = '{}/{}/{}/{}-{}{}.jar'.format(group.replace('.', '/'), artifact, ver, artifact, ver, classifier)
    if not path:
        continue
    full = os.path.join(mc_dir, 'libraries', path.replace('/', os.sep))
    if os.path.isfile(full):
        libs.append(win(full))
    else:
        skipped += 1

# --- patched Minecraft / NeoForge jars ------------------------------------
neoforge_jars = sorted(glob.glob(os.path.join(mc_dir, 'libraries', 'net', 'neoforged', 'neoforge', '*', '*.jar')))
patched = [j for j in neoforge_jars if j.endswith('-client.jar')]
# the patched classes have to be seen first, otherwise the vanilla client jar shadows them
libs = [win(p) for p in patched] + libs + [win(j) for j in neoforge_jars if j not in patched]
libs += [win(j) for j in sorted(glob.glob(os.path.join(mc_dir, 'libraries', 'net', 'minecraft', 'client', '*', 'client-*.jar')))]

# --- mods + nested jar-in-jar libraries -----------------------------------
index = 0
for mod_jar in sorted(glob.glob(os.path.join(game_dir, 'mods', '*.jar'))):
    stem = ascii_name(os.path.splitext(os.path.basename(mod_jar))[0])
    copy = os.path.join(deps_dir, 'mod{:03d}_{}.jar'.format(index, stem))
    index += 1
    shutil.copyfile(mod_jar, copy)
    libs.append(win(copy))
    try:
        with zipfile.ZipFile(mod_jar) as archive:
            nested = [n for n in archive.namelist() if n.startswith('META-INF/jarjar/') and n.endswith('.jar')]
            for entry in nested:
                inner = os.path.join(deps_dir, 'jij{:03d}_{}.jar'.format(index, ascii_name(entry[:-4].split('/')[-1])))
                index += 1
                with archive.open(entry) as src, open(inner, 'wb') as dst:
                    shutil.copyfileobj(src, dst)
                libs.append(win(inner))
    except zipfile.BadZipFile:
        print('    WARN: not a zip file: {}'.format(mod_jar))

# dedupe, keep order
seen = set()
ordered = []
for entry in libs:
    if entry not in seen:
        seen.add(entry)
        ordered.append(entry)

with open(cp_file, 'w', encoding='utf-8') as handle:
    handle.write('-cp\n"' + ';'.join(ordered) + '"\n')

print('    {} classpath entries ({} mod/nested jars, {} other-platform libraries skipped)'
      .format(len(ordered), index, skipped))
PYEOF

# ---------------------------------------------------------------------------
# 2) Compile
# ---------------------------------------------------------------------------
cd "$PROJECT_DIR"
find src/main/java -name '*.java' | sort > "$BUILD_DIR/sources.txt"
echo "==> compiling $(wc -l < "$BUILD_DIR/sources.txt") source file(s)"
"$JAVAC" -proc:none -encoding UTF-8 --release 21 -d "$CLASSES_DIR" \
    @"$BUILD_DIR/cp.args" @"$BUILD_DIR/sources.txt"

# ---------------------------------------------------------------------------
# 3) Resources + jar
# ---------------------------------------------------------------------------
cp -R src/main/resources/. "$CLASSES_DIR/"

# A small manifest: purely informational, but it gives the jar a proper module name.
cat > "$BUILD_DIR/MANIFEST.MF" <<EOF
Manifest-Version: 1.0
Automatic-Module-Name: cc.cszt0.cnilavastrokefix
Implementation-Title: CNI Lava Stroke Engine NPE Fix
Implementation-Version: $MOD_VERSION
Implementation-Vendor: chushi0
EOF

"$JAR_TOOL" --create --file "$JAR_FILE" --manifest "$BUILD_DIR/MANIFEST.MF" -C "$CLASSES_DIR" .
echo "==> built $JAR_FILE"
"$JAR_TOOL" --list --file "$JAR_FILE" | sort

# The copy of the instance's jars is only needed while compiling (it is ~400 MB), the next build
# recreates it. Keep it when the build failed so the classpath can be inspected.
rm -rf "$DEPS_DIR"

# ---------------------------------------------------------------------------
# 4) Optional install into the instance
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--install" ]; then
    if [ ! -d "$INSTALL_DIR" ]; then
        echo "ERROR: mods folder not found: $INSTALL_DIR"
        exit 1
    fi
    cp -f "$JAR_FILE" "$INSTALL_DIR/$JAR_NAME.jar"
    echo "==> installed to $INSTALL_DIR/$JAR_NAME.jar"
    echo "    (delete that file again to uninstall the fix)"
fi
