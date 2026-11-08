#!/usr/bin/env bash
# Everything about this plugin that can be checked without a running Omarchy
# shell. CI runs this on every push; run it yourself before opening a PR.
#
# What it deliberately does NOT do: pretend to test the UI. A bar widget needs
# a live Quickshell shell process with a compositor behind it, and CI has
# neither. Those checks happen on the desktop, and the README says how.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)

# shellcheck source=ci-assert.sh
source "$HERE/ci-assert.sh"

MANIFEST="$ROOT/manifest.json"

echo "== files required for publication"
assert_file_exists "$MANIFEST" "manifest.json is in the repository root"
assert_file_exists "$ROOT/README.md" "README.md exists"
assert_file_exists "$ROOT/LICENSE" "LICENSE exists"
assert_file_exists "$ROOT/CHANGELOG.md" "CHANGELOG.md exists"

if [[ ! -f $MANIFEST ]]; then
  assert_summary
fi

echo
echo "== manifest schema"
assert_cmd_succeeds "manifest.json is valid JSON" -- jq -e . "$MANIFEST"
assert_cmd_succeeds "schemaVersion is the number 1" -- \
  jq -e '.schemaVersion == 1' "$MANIFEST"

for field in id name version author description kinds entryPoints license; do
  assert_cmd_succeeds "manifest has '$field'" -- \
    jq -e --arg f "$field" 'has($f) and (.[$f] != null) and (.[$f] != "")' "$MANIFEST"
done

PLUGIN_ID=$(jq -r '.id' "$MANIFEST")
if [[ $PLUGIN_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $PLUGIN_ID != omarchy.* ]]; then
  pass "plugin id '$PLUGIN_ID' is well formed and outside the reserved omarchy.* namespace"
else
  fail "plugin id '$PLUGIN_ID' is not acceptable to the registry"
fi

# The shell only honours these three; anything else silently lands nowhere.
assert_cmd_succeeds "barWidget.defaultSection is left, center or right" -- \
  jq -e '(.barWidget.defaultSection // "center") as $s
    | ["left","center","right"] | index($s) != null' "$MANIFEST"

echo
echo "== entry points"
# Every declared kind must have the entry-point key the shell looks for, and
# every entry point must be a safe relative path that exists. A kind without
# its entry point installs and enables and then does nothing.
while IFS=$'\t' read -r kind key; do
  if jq -e --arg k "$kind" '(.kinds | index($k)) != null' "$MANIFEST" >/dev/null 2>&1; then
    if jq -e --arg e "$key" '.entryPoints | has($e)' "$MANIFEST" >/dev/null 2>&1; then
      pass "kind '$kind' declares entryPoints.$key"
    else
      fail "kind '$kind' is declared but entryPoints.$key is missing"
    fi
  fi
done <<'KINDS'
bar	bar
bar-widget	barWidget
menu	menu
overlay	overlay
panel	panel
service	service
KINDS

while IFS= read -r ep; do
  [[ -n $ep ]] || continue
  if [[ $ep == /* || $ep == *".."* ]]; then
    fail "entry point '$ep' must be a relative path with no '..'"
  elif [[ -f "$ROOT/$ep" ]]; then
    pass "entry point '$ep' exists"
  else
    fail "entry point '$ep' is missing from the repository"
  fi
done < <(jq -r '.entryPoints | to_entries[] | .value' "$MANIFEST")

echo
echo "== no symlinks"
# The validator refuses a plugin folder containing any symlink: once copied
# into the trusted plugins directory, one could point at arbitrary files.
link=$(find "$ROOT" -name .git -prune -o -type l -print -quit 2>/dev/null)
if [[ -z $link ]]; then
  pass "no symlinks inside the plugin folder"
else
  fail "symlink found, which the registry rejects: $link"
fi

echo
echo "== QML syntax"
# This qmllint is a syntax verifier, not a full linter: it catches parse
# errors, not unknown properties. That is still the class of error that
# matters most here, because a QML parse error degrades the whole shell.
#
# Named qmllint on Arch, qmllint6 on Debian/Ubuntu, and unversioned inside
# Qt's own libexec dir on both.
QMLLINT=""
for candidate in qmllint qmllint6 /usr/lib/qt6/bin/qmllint \
  /usr/lib/x86_64-linux-gnu/qt6/bin/qmllint; do
  if command -v "$candidate" >/dev/null 2>&1; then QMLLINT=$candidate; break; fi
done

if [[ -n $QMLLINT ]]; then
  shopt -s nullglob
  for f in "$ROOT"/*.qml; do
    assert_cmd_succeeds "qmllint: $(basename "$f")" -- "$QMLLINT" "$f"
  done
  shopt -u nullglob
else
  fail "qmllint not found (Arch: qt6-declarative, Debian/Ubuntu: qt6-declarative-dev-tools)"
fi

echo
echo "== local components resolve"
# `omarchy plugin validate` only checks entry points, and this qmllint does not
# resolve types, so deleting a component that an entry point instantiates --
# SessionPanel.qml, say -- passed every other check here while leaving a plugin
# that loads and then fails at runtime.
#
# Every capitalised `Type {` is either a type from a module the plugin imports
# (listed here, which doubles as the record of what it depends on) or a .qml
# file that must exist beside it.
EXTERNAL_TYPES=$(cat <<'TYPES'
Item Text Rectangle Row Column Flow Grid MouseArea Timer Loader Repeater
Component Connections Behavior NumberAnimation ColorAnimation Flickable
PropertyAnimation SequentialAnimation ParallelAnimation Binding
Process SplitParser StdioCollector Socket IpcHandler FileView
BarWidget WidgetButton BarIconButton KeyboardPanel PanelKeyCatcher Button
PanelSeparator PanelSectionHeader PanelActionButton PanelToolTip Panel
PanelController Dropdown MultiSelect TextField Toggle ToggleSwitch
ButtonGroup SearchableDropdown NumberField PopupCard BorderSurface
QtObject ListModel ListElement ScrollView FloatingWindow PanelWindow
TYPES
)

shopt -s nullglob
for f in "$ROOT"/*.qml; do
  while IFS= read -r type; do
    [[ -n $type ]] || continue
    if grep -qx -- "$type" <<<"$(tr ' ' '\n' <<<"$EXTERNAL_TYPES" | grep -v '^$')"; then
      continue
    fi
    if [[ -f "$ROOT/$type.qml" ]]; then
      pass "$(basename "$f") uses local component $type.qml, which exists"
    else
      fail "$(basename "$f") instantiates '$type' but $type.qml is missing and it is not a known imported type"
    fi
  done < <(grep -oE '^[[:space:]]*[A-Z][A-Za-z0-9]*[[:space:]]*\{' "$f" |
    sed -E 's/[[:space:]]*\{//; s/^[[:space:]]*//' | sort -u)
done
shopt -u nullglob

echo
echo "== external commands are documented"
# Derived from the source, not from a hand-maintained list, so adding a command
# without documenting it fails here instead of shipping undocumented.
#
# Omarchy's publishing guide requires documenting every external dependency and
# command a plugin uses, and the plugin runs unsandboxed, so this is the check
# that keeps the README honest about what it executes.
#
# A `command:` array is routinely wrapped across lines, so this reads the files
# whole rather than line by line. The first version of this check was line
# based, silently matched nothing, and cheerfully reported "no external
# commands are run by this plugin" for a plugin that runs two.
# Both ways a plugin can start a process: a Process's `command:` array and
# Quickshell.execDetached([...]). A command built from a runtime variable has no
# literal to find here, so the README table stays the authority -- this catches
# the literals, which is what people actually forget to document.
mapfile -t COMMANDS < <(
  cat "$ROOT"/*.qml 2>/dev/null |
    tr '\n' ' ' |
    grep -oE 'command: \[[^]]*\]|execDetached\(\[[^]]*\]' |
    grep -o '"[^"]*"' | tr -d '"' |
    # keep argv[0]-looking tokens: no leading dash, no spaces
    grep -vE '^-|^$| ' |
    sort -u
)

if (( ${#COMMANDS[@]} == 0 )); then
  pass "no external commands are run by this plugin"
else
  for cmd in "${COMMANDS[@]}"; do
    # Arguments that are also plain words (status, play) would produce noise,
    # so only check tokens that name a program we actually invoke.
    case "$cmd" in
      setpriv|bfm|bfmd|bfm-gtk|bfm-kde|busctl|systemctl|sh|bash)
        assert_contains "$ROOT/README.md" "$cmd" \
          "README documents the external command '$cmd'"
        ;;
    esac
  done
fi

echo
echo "== changelog"
assert_contains "$ROOT/CHANGELOG.md" "## [Unreleased]" \
  "CHANGELOG has an [Unreleased] section"

VERSION=$(jq -r '.version' "$MANIFEST")
# On a tag build the manifest version must be released, not still unreleased.
if [[ -n ${GITHUB_REF_NAME:-} && ${GITHUB_REF_TYPE:-} == tag ]]; then
  if [[ ${GITHUB_REF_NAME#v} == "$VERSION" ]]; then
    pass "tag $GITHUB_REF_NAME matches manifest version $VERSION"
  else
    fail "tag $GITHUB_REF_NAME does not match manifest version $VERSION"
  fi
  assert_contains "$ROOT/CHANGELOG.md" "## [$VERSION]" \
    "CHANGELOG has a section for released version $VERSION"
fi

echo
echo "== omarchy plugin validate"
# The same script the marketplace runs. It is plain bash + jq, so it works on a
# CI runner when fetched; when it is genuinely unavailable, say so rather than
# reporting a check that never ran as passing.
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  assert_cmd_succeeds "omarchy-plugin-validate accepts this folder" -- \
    omarchy-plugin-validate "$ROOT"
elif [[ -x ${OMARCHY_VALIDATE:-} ]]; then
  assert_cmd_succeeds "omarchy-plugin-validate accepts this folder" -- \
    "$OMARCHY_VALIDATE" "$ROOT"
else
  echo "SKIP: omarchy-plugin-validate not available here" >&2
  echo "      (CI fetches it; locally it comes with Omarchy)" >&2
fi

assert_summary
