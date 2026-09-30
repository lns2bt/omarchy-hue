#!/usr/bin/env bash
# Remove the manually installed plugin; preserve pairing unless --purge is given.
set -euo pipefail

usage() {
  printf 'Usage: %s [--purge]\n' "$0"
}

die() {
  printf 'omarchy-hue: %s\n' "$*" >&2
  exit 1
}

purge=false
case "${1:-}" in
  "") ;;
  --purge) purge=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }

config_home=${XDG_CONFIG_HOME:-$HOME/.config}
destination="$config_home/omarchy/plugins/local.hue"
credentials="$config_home/omarchy/hue.json"
favorites="$config_home/omarchy/hue-favorites.json"

command -v omarchy >/dev/null || die "Missing command: omarchy"
command -v omarchy-shell >/dev/null || die "Missing command: omarchy-shell"
command -v python3 >/dev/null || die "Missing command: python3"
omarchy-shell shell ping >/dev/null || die "Omarchy shell is not running. Log into an Omarchy session first."

[[ ! -L "$destination" ]] || die "Refusing to remove a symlink: $destination"
[[ -d "$destination" ]] || die "Plugin directory not found: $destination"
[[ ! -d "$destination/.git" ]] || die "This plugin is git-managed; use 'omarchy plugin remove local.hue --yes' instead."
if "$purge"; then
  [[ ! -L "$credentials" ]] || die "Refusing to remove a symlink: $credentials"
  [[ ! -L "$favorites" ]] || die "Refusing to remove a symlink: $favorites"
fi
python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1], encoding="utf-8")).get("id") != "local.hue")' "$destination/manifest.json" \
  || die "The directory does not contain a local.hue plugin."

omarchy plugin disable local.hue
rm -r -- "$destination"
omarchy-shell shell rescanPlugins >/dev/null
if "$purge"; then
  rm -f -- "$credentials"
  rm -f -- "$favorites"
  printf 'Plugin and local pairing removed.\n'
else
  printf 'Plugin removed. Local pairing kept at %s (use --purge to delete it).\n' "$credentials"
fi
