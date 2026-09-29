#!/usr/bin/env bash
# Install this checkout as a user-owned Omarchy bar plugin.
set -euo pipefail

usage() {
  printf 'Usage: %s [--upgrade]\n' "$0"
}

die() {
  printf 'omarchy-hue: %s\n' "$*" >&2
  exit 1
}

upgrade=false
case "${1:-}" in
  "") ;;
  --upgrade) upgrade=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }

source_dir=$(dirname "$(realpath "$0")")
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
state_home=${XDG_STATE_HOME:-$HOME/.local/state}
destination="$config_home/omarchy/plugins/local.hue"
backup_dir="$state_home/omarchy-hue/backups"

for executable in python3 omarchy omarchy-shell; do
  command -v "$executable" >/dev/null || die "Missing required command: $executable"
done
for file in manifest.json HuePanel.qml hue.py; do
  [[ -f "$source_dir/$file" ]] || die "Missing source file: $file"
done
omarchy-shell shell ping >/dev/null || die "Omarchy shell is not running. Log into an Omarchy session first."

[[ ! -L "$destination" ]] || die "Refusing to replace a symlink: $destination"
if [[ -e "$destination" ]]; then
  [[ -d "$destination" ]] || die "Plugin path is not a directory: $destination"
  [[ ! -d "$destination/.git" ]] || die "This plugin is git-managed; use 'omarchy plugin update local.hue --yes' instead."
  "$upgrade" || die "A Hue plugin already exists. Run './install.sh --upgrade' to back it up and update it."
  mkdir -p "$backup_dir"
  backup=$(mktemp -d "$backup_dir/local.hue-XXXXXXXX")
  cp -a "$destination/." "$backup/"
  printf 'Existing plugin backed up to %s\n' "$backup"
else
  mkdir -p "$destination"
fi

install -m 0644 "$source_dir/manifest.json" "$destination/manifest.json"
install -m 0644 "$source_dir/HuePanel.qml" "$destination/HuePanel.qml"
install -m 0644 "$source_dir/hue.py" "$destination/hue.py"

omarchy-shell shell rescanPlugins >/dev/null
if omarchy-shell shell listPlugins | python3 -c 'import json,sys; sys.exit(not any(p["id"] == "local.hue" and p["enabled"] for p in json.load(sys.stdin)))'; then
  printf 'Hue plugin updated and already enabled.\n'
else
  mkdir -p "$backup_dir"
  if [[ -f "$config_home/omarchy/shell.json" ]]; then
    config_backup=$(mktemp "$backup_dir/shell.json-XXXXXXXX")
    cp -p "$config_home/omarchy/shell.json" "$config_backup"
    printf 'Bar configuration backed up to %s\n' "$config_backup"
  fi
  if omarchy-shell shell listPlugins | python3 -c 'import json,sys; sys.exit(not any(p["id"] == "omarchy.bluetooth" and p["enabled"] for p in json.load(sys.stdin)))'; then
    omarchy plugin enable local.hue --section right --before omarchy.bluetooth
  else
    omarchy plugin enable local.hue --section right
  fi
fi

printf 'Hue is ready in the Omarchy bar. Click the lightbulb to connect a bridge.\n'
printf 'Existing pairing is preserved in %s/omarchy/hue.json (if present).\n' "$config_home"
