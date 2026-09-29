# Hue for Omarchy

A Philips Hue control panel for the Omarchy status bar. It uses Omarchy's native Quickshell panel, theme colors, and controls alongside the Wi-Fi and Bluetooth widgets. It talks directly to a Hue Bridge on your local network using the Hue CLIP API v2, including the Hue Bridge Pro.

## Features

- **All:** switch or dim every light through the bridge-home grouped-light service; choose a color for color-capable lights.
- **Groups:** browse Hue rooms and zones in a compact grid, then switch, dim, or color the selected group.
- **Lights:** browse individual bulbs and control each one separately.
- Color swatches and a `#RRGGBB` field. White-only lights can still be switched and dimmed; mixed groups send color only to compatible lights.
- Automatic discovery using local mDNS (`avahi-browse`) with Hue's discovery endpoint as a fallback; manual local IP entry always works.
- Errors remain visible next to the controls until you start another action.

## Requirements

- An Omarchy installation with the Quickshell-based `omarchy-shell` and its `qs.Ui` components.
- Python 3 (standard library only); no Hue account or Python packages required.
- A reachable Hue Bridge on the same local network. Pressing the bridge button is required once to authorize the app.
- Optional: `avahi-browse` for local mDNS discovery. If discovery fails, enter the bridge's local IPv4 address.

## Install

While logged into an Omarchy desktop session:

```sh
git clone https://github.com/lns2bt/omarchy-hue.git
cd omarchy-hue
bash install.sh
```

The installer copies `manifest.json`, `HuePanel.qml`, and `hue.py` to `~/.config/omarchy/plugins/local.hue/`, rescans plugins, and enables the widget on the right side of the bar (before Bluetooth when available). It needs no root privileges. To update a previously *manually installed* copy, run:

```sh
bash install.sh --upgrade
```

`--upgrade` backs up the existing plugin under `${XDG_STATE_HOME:-~/.local/state}/omarchy-hue/backups/`. When first enabling the widget, the installer also backs up `shell.json` there. It does not overwrite an existing plugin unless you explicitly use `--upgrade`. It does not alter or copy your bridge credentials.

The repository root also contains `manifest.json`, so you can use Omarchy's native plugin installer instead:

```sh
omarchy plugin add https://github.com/lns2bt/omarchy-hue.git --enable --yes
omarchy plugin update local.hue --yes
```

Use the `omarchy plugin` commands, rather than `install.sh`, to manage a git-installed copy.

## Pair a bridge

1. Click the lightbulb icon in the bar. Select **Discover** or enter your bridge's local IPv4 address and click **Connect**.
2. Check the displayed SHA-256 certificate fingerprint and click **Trust bridge**. The first connection is explicit trust-on-first-use; the certificate is pinned for later requests. A changed certificate requires confirmation again.
3. Press the physical button on the Hue Bridge and click **Press button & pair**. The panel retries briefly during the bridge's pairing window.
4. Choose **All**, **Groups**, or **Lights** and control the selected scope.

The IP address, pinned fingerprint, and application key are stored in `${XDG_CONFIG_HOME:-~/.config}/omarchy/hue.json` with `0600` permissions. Credentials are never part of this repository, the plugin manifest, or Omarchy's `shell.json`. All lighting commands use the local bridge over HTTPS. Discovery may contact `discovery.meethue.com` if local mDNS does not find a bridge; entering the IP avoids discovery.

## Uninstall

For a manually installed copy:

```sh
bash uninstall.sh
```

This disables the widget and removes its code, retaining `hue.json` so a reinstall keeps the pairing. To also delete local pairing data:

```sh
bash uninstall.sh --purge
```

For a plugin installed with `omarchy plugin add`, use `omarchy plugin remove local.hue --yes` instead. To remove pairing data as well, delete your `hue.json` separately.

## Development

```sh
python3 -B -m unittest discover -s tests -v
```

`hue.py` is a small JSON-over-stdout helper. It reads the Hue v2 resource graph, maps rooms and zones to grouped-light services, translates RGB colors to CIE xy, and makes pinned HTTPS requests. When all lights in a selection support color, a single grouped-light PUT avoids a burst of per-light writes; mixed groups target color-capable lights individually.

API references: [authentication](https://www.openhue.io/api/openhue-api-1/auth.md), [resources](https://www.openhue.io/api/openhue-api-1/resource.md), [lights](https://www.openhue.io/api/openhue-api-1/light.md), [grouped lights](https://www.openhue.io/api/openhue-api-1/grouped-light.md), [rooms](https://www.openhue.io/api/openhue-api-1/room.md), and [zones](https://www.openhue.io/api/openhue-api-1/zone.md).

Licensed under MIT. Philips Hue is a trademark of Signify; this community project is not affiliated with Signify.
