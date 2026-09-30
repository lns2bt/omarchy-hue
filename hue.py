#!/usr/bin/env python3
"""Local Hue CLIP v2 adapter for the Omarchy Hue bar widget (JSON on stdout)."""

import hashlib
import http.client
import ipaddress
import json
import math
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request


CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omarchy" / "hue.json"
FAVORITES = CONFIG.with_name("hue-favorites.json")
UUID_CHARS = set("0123456789abcdef-")


class HueError(Exception):
    pass


class HueAuthError(HueError):
    pass


class HueCertificateError(HueError):
    pass


def address(value):
    try:
        ip = ipaddress.ip_address(value)
        if ip.version != 4 or not (ip.is_private or ip.is_link_local):
            raise ValueError()
        return str(ip)
    except ValueError as exc:
        raise HueError("Enter the bridge's local IPv4 address.") from exc


def load():
    try:
        if CONFIG.is_symlink() or CONFIG.stat().st_mode & 0o077:
            raise HueError("Hue configuration has insecure permissions (expected: 0600).")
        return json.loads(CONFIG.read_text())
    except FileNotFoundError:
        return {}


def save(data, destination=CONFIG):
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, path = tempfile.mkstemp(prefix=".hue-", dir=destination.parent)
    try:
        with os.fdopen(fd, "w") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(data, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(path, destination)
    finally:
        if os.path.exists(path):
            os.unlink(path)


def fingerprint(ip):
    # Hue's local bridge certificate is self-signed. Trust on explicit first use,
    # then pin its SHA-256 fingerprint for all API calls.
    context = ssl._create_unverified_context()
    with socket.create_connection((address(ip), 443), timeout=4) as raw:
        with context.wrap_socket(raw, server_hostname=ip) as tls:
            return hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()


class PinnedConnection(http.client.HTTPSConnection):
    def __init__(self, ip, expected):
        super().__init__(ip, timeout=5, context=ssl._create_unverified_context())
        self.expected = expected

    def connect(self):
        super().connect()
        actual = hashlib.sha256(self.sock.getpeercert(binary_form=True)).hexdigest()
        if actual != self.expected:
            self.close()
            raise HueCertificateError("The bridge certificate has changed. Please trust the bridge again.")


def request(config, method, path, body=None):
    conn = PinnedConnection(address(config["ip"]), config["fingerprint"])
    headers = {"Accept": "application/json"}
    if config.get("key") and path != "/api":
        headers["hue-application-key"] = config["key"]
    if body is not None:
        headers["Content-Type"] = "application/json"
    try:
        conn.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        response = conn.getresponse()
        raw = response.read()
        result = json.loads(raw) if raw else {}
        if response.status >= 400:
            errors = result.get("errors", "") if isinstance(result, dict) else result
            error_type = HueAuthError if response.status in (401, 403) else HueError
            raise error_type("Bridge returned HTTP %d. %s" % (response.status, errors))
        if isinstance(result, dict) and result.get("errors"):
            error = result["errors"][0]
            raise HueError(str(error.get("description", error) if isinstance(error, dict) else error))
        return result
    finally:
        conn.close()


def paired(config):
    if not config.get("ip") or not config.get("fingerprint"):
        raise HueError("Connect a bridge first.")
    if not config.get("key"):
        raise HueError("Press the bridge button and pair first.")


def resources(config):
    paired(config)
    result = request(config, "GET", "/clip/v2/resource")
    if not isinstance(result, dict) or not isinstance(result.get("data"), list):
        raise HueError("The bridge returned an invalid resource list.")
    return result["data"]


def ref(services, kind):
    return next((item["rid"] for item in services if item.get("rtype") == kind), None)


def members(group, lights, owners):
    children = group.get("children", [])
    devices = {item["rid"] for item in children if item.get("rtype") == "device"}
    services = {item["rid"] for item in children if item.get("rtype") == "light"}
    return [light for light in lights if light["id"] in services or owners.get(light["id"]) in devices]


def snapshot(items):
    by_type = {}
    for item in items:
        by_type.setdefault(item.get("type"), []).append(item)
    devices = {item["id"]: item for item in by_type.get("device", [])}
    grouped = {item["id"]: item for item in by_type.get("grouped_light", [])}
    lights = []
    owners = {}
    for light in by_type.get("light", []):
        owners[light["id"]] = light.get("owner", {}).get("rid")
        owner = devices.get(owners[light["id"]], {})
        lights.append({"id": light["id"], "name": owner.get("metadata", {}).get("name") or light.get("metadata", {}).get("name") or "Light",
                       "on": light.get("on", {}).get("on", False),
                       "brightness": light.get("dimming", {}).get("brightness"),
                       "color": "color" in light, "xy": light.get("color", {}).get("xy")})
    lights.sort(key=lambda x: x["name"].casefold())
    groups = []
    for kind, label in (("room", "Room"), ("zone", "Zone")):
        for group in by_type.get(kind, []):
            service = ref(group.get("services", []), "grouped_light")
            if service:
                relevant = members(group, lights, owners)
                state = grouped.get(service, {})
                groups.append({"id": group["id"], "name": group.get("metadata", {}).get("name", label),
                               "kind": label, "service": service, "color": any(l["color"] for l in relevant),
                               "on": state.get("on", {}).get("on", False),
                               "brightness": state.get("dimming", {}).get("brightness")})
    groups.sort(key=lambda x: (x["kind"], x["name"].casefold()))
    homes = by_type.get("bridge_home", [])
    home_service = ref(homes[0].get("services", []), "grouped_light") if homes else None
    home_state = grouped.get(home_service, {})
    bridge_id = next((b.get("bridge_id") for b in by_type.get("bridge", []) if b.get("bridge_id")), None)
    group_map = {g["id"]: g for g in groups}
    scenes = []
    for scene in by_type.get("scene", []):
        group_id = scene.get("group", {}).get("rid")
        if group_id not in group_map:
            continue
        scenes.append({"id": scene["id"], "name": scene.get("metadata", {}).get("name", "Scene"),
                       "group": group_id, "groupName": group_map[group_id]["name"],
                       "active": scene.get("status", {}).get("active", "inactive")})
    scenes.sort(key=lambda s: (s["groupName"].casefold(), s["name"].casefold()))
    return {"lights": lights, "groups": groups, "scenes": scenes, "bridgeId": bridge_id,
            "favorites": favorite_entries(bridge_id), "home": home_service,
            "on": home_state.get("on", {}).get("on", any(light["on"] for light in lights)),
            "brightness": home_state.get("dimming", {}).get("brightness"),
            "color": any(light["color"] for light in lights), "paired": True}


def favorite_store():
    try:
        data = json.loads(FAVORITES.read_text())
        if not isinstance(data, dict) or not isinstance(data.get("bridges", {}), dict):
            raise ValueError()
        return data
    except FileNotFoundError:
        return {"bridges": {}}
    except (ValueError, OSError) as exc:
        raise HueError("Could not read favorites. Check hue-favorites.json.") from exc


def favorite_entries(bridge_id):
    if not bridge_id:
        return []
    entries = favorite_store().get("bridges", {}).get(bridge_id, [])
    if not isinstance(entries, list) or any(not isinstance(e, dict) or e.get("kind") not in ("group", "scene")
                                           or not isinstance(e.get("id"), str) for e in entries):
        raise HueError("Invalid favorites for this bridge.")
    return entries


def favorite(config, kind, target, enabled):
    view = snapshot(resources(config))
    bridge_id = view["bridgeId"]
    if not bridge_id:
        raise HueError("The bridge did not provide its identity.")
    if kind not in ("group", "scene") or enabled not in ("true", "false"):
        raise HueError("Invalid favorite action.")
    collection = view["groups"] if kind == "group" else view["scenes"]
    if enabled == "true" and not any(x["id"] == target for x in collection):
        raise HueError("Favorite resource no longer exists.")
    store = favorite_store()
    entries = [e for e in favorite_entries(bridge_id) if not (e["kind"] == kind and e["id"] == target)]
    if enabled == "true":
        entries.append({"kind": kind, "id": target})
    store.setdefault("bridges", {})[bridge_id] = entries
    save(store, FAVORITES)
    view["favorites"] = entries
    return {"state": view}


def recall(config, target):
    view = snapshot(resources(config))
    if not any(s["id"] == target for s in view["scenes"]):
        raise HueError("Scene no longer exists on this bridge.")
    request(config, "PUT", "/clip/v2/resource/scene/" + resource_id(target), {"recall": {"action": "active"}})
    return after_write(config)


def after_write(config, warning=""):
    result = {"applied": True}
    try:
        result["state"] = snapshot(resources(config))
    except (HueError, OSError, http.client.HTTPException, json.JSONDecodeError) as exc:
        suffix = "Bridge accepted the change, but its current state could not be read: %s" % exc
        warning = (warning + " " + suffix).strip()
    if warning:
        result["warning"] = warning
    return result


def rgb_xy(hex_color):
    if len(hex_color) != 7 or hex_color[0] != "#" or any(c not in "0123456789abcdefABCDEF" for c in hex_color[1:]):
        raise HueError("Invalid color. Use #RRGGBB.")
    rgb = [int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    rgb = [((c + 0.055) / 1.055) ** 2.4 if c > 0.04045 else c / 12.92 for c in rgb]
    r, g, b = rgb
    x = r * 0.664511 + g * 0.154324 + b * 0.162028
    y = r * 0.283881 + g * 0.668433 + b * 0.047685
    z = r * 0.000088 + g * 0.072310 + b * 0.986039
    total = x + y + z
    if total <= 0:
        raise HueError("Black is not a light color; use the switch to turn lights off.")
    return {"x": round(x / total, 5), "y": round(y / total, 5)}


def color_brightness(hex_color):
    # RGB value in an HSV-style picker represents the light's brightness.
    # The CIE xy coordinate alone does not carry luminance information.
    return max(1, round(max(int(hex_color[i:i + 2], 16) for i in (1, 3, 5)) / 255 * 100, 1))


def resource_id(value):
    if len(value) != 36 or any(c not in UUID_CHARS for c in value.lower()):
        raise HueError("Invalid resource ID.")
    return value


def control(config, kind, target, operation, value):
    items = resources(config)
    view = snapshot(items)
    if kind == "all":
        service = view["home"]
        affected = view["lights"]
    elif kind == "group":
        group = next((g for g in view["groups"] if g["id"] == target), None)
        if not group:
            raise HueError("Group not found.")
        service = group["service"]
        raw_group = next(x for x in items if x.get("id") == target)
        owners = {x["id"]: x.get("owner", {}).get("rid") for x in items if x.get("type") == "light"}
        affected = members(raw_group, view["lights"], owners)
    elif kind == "light":
        affected = [l for l in view["lights"] if l["id"] == target]
        if not affected:
            raise HueError("Light not found.")
        service = target
    else:
        raise HueError("Unknown control scope.")

    warning = ""
    if operation == "color":
        colored = [l for l in affected if l["color"]]
        if not colored:
            raise HueError("No color-capable lights in this selection.")
        xy = rgb_xy(value)
        payload = {"on": {"on": True}, "color": {"xy": xy},
                   "dimming": {"brightness": color_brightness(value)}}
        if kind != "light" and service and len(colored) == len(affected):
            # One group write avoids a burst of individual PUTs (and bridge
            # throttling), but only when every member can accept a color.
            request(config, "PUT", "/clip/v2/resource/grouped_light/" + resource_id(service), payload)
        else:
            for index, light in enumerate(colored):
                try:
                    request(config, "PUT", "/clip/v2/resource/light/" + resource_id(light["id"]), payload)
                except (HueError, OSError, http.client.HTTPException, json.JSONDecodeError) as exc:
                    if index == 0:
                        raise HueError("Could not set color for %s: %s" % (light["name"], exc)) from exc
                    warning = "%d of %d lights accepted the color. %s failed: %s" % (
                        index, len(colored), light["name"], exc)
                    break
                if index < len(colored) - 1:
                    time.sleep(0.12)
    else:
        if not service:
            raise HueError("No group service is available on the bridge.")
        if operation == "on":
            payload = {"on": {"on": value == "true"}}
        elif operation == "brightness":
            try:
                brightness = float(value)
                if not math.isfinite(brightness) or not 1 <= brightness <= 100:
                    raise ValueError()
            except ValueError as exc:
                raise HueError("Brightness must be between 1 and 100.") from exc
            payload = {"dimming": {"brightness": brightness}, "on": {"on": True}}
        else:
            raise HueError("Unknown action.")
        endpoint = "light" if kind == "light" else "grouped_light"
        request(config, "PUT", "/clip/v2/resource/%s/%s" % (endpoint, resource_id(service)), payload)
    # The PUT was accepted by the bridge. A subsequent GET may fail even though
    # the lights changed; never report that as a failed write or blindly retry.
    return after_write(config, warning)


def main(args):
    config = load()
    command = args[0] if args else "status"
    if command == "recall" and len(args) == 2:
        return recall(config, args[1])
    if command == "favorite" and len(args) == 4:
        return favorite(config, *args[1:])
    if command == "discover":
        found = []
        try:
            scan = subprocess.run(["avahi-browse", "-rtp", "_hue._tcp"],
                                  capture_output=True, text=True, timeout=4, check=False)
            for line in scan.stdout.splitlines():
                parts = line.split(";")
                if len(parts) >= 8 and parts[0] == "=" and parts[2] == "IPv4":
                    found.append({"ip": address(parts[7]), "id": parts[3]})
        except (OSError, subprocess.TimeoutExpired):
            pass
        if found:
            return {"bridges": list({item["ip"]: item for item in found}.values())}
        try:
            with urllib.request.urlopen("https://discovery.meethue.com/", timeout=4) as response:
                found = json.load(response)
            return {"bridges": [{"ip": address(x["internalipaddress"]), "id": x.get("id", "")}
                                 for x in found if "internalipaddress" in x]}
        except (OSError, ValueError, KeyError):
            return {"bridges": [], "error": "Bridge not found. Enter its IP address manually."}
    if command == "probe" and len(args) == 2:
        ip = address(args[1])
        return {"ip": ip, "fingerprint": fingerprint(ip)}
    if command == "trust" and len(args) == 3:
        ip = address(args[1])
        expected = args[2].lower()
        if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
            raise HueError("Invalid certificate fingerprint.")
        if fingerprint(ip) != expected:
            raise HueError("The certificate changed since it was checked.")
        key = config.get("key", "") if config.get("ip") == ip and config.get("fingerprint") == expected else ""
        save({"ip": ip, "fingerprint": expected, "key": key})
        return {"trusted": True, "paired": bool(key)}
    if command == "pair":
        if not config.get("fingerprint"):
            raise HueError("Trust the bridge first.")
        result = request(config, "POST", "/api", {"devicetype": "omarchy_hue#laptop"})
        if not isinstance(result, list) or not result:
            raise HueError("Unexpected pairing response from the bridge.")
        if "error" in result[0]:
            error = result[0]["error"]
            if error.get("type") == 101:
                return {"waiting": True, "message": "Press the button on the bridge."}
            raise HueError(error.get("description", "Pairing failed."))
        key = result[0].get("success", {}).get("username")
        if not key:
            raise HueError("The bridge did not return an application key.")
        config["key"] = key
        save(config)
        return {"paired": True}
    if command == "status":
        if not config.get("key"):
            return {"paired": False, "trusted": bool(config.get("fingerprint")), "ip": config.get("ip", "")}
        try:
            return dict(snapshot(resources(config)), ip=config["ip"])
        except HueAuthError as exc:
            # A 403 can also mean insufficient permission or a temporary
            # bridge condition. Keep the key; manual re-pairing replaces it.
            return {"paired": False, "trusted": True, "ip": config["ip"],
                    "authError": True,
                    "message": "Bridge rejected access (%s). Your key was kept. Retry or pair again." % exc}
        except (HueError, OSError, http.client.HTTPException, json.JSONDecodeError) as exc:
            return {"paired": True, "offline": True, "ip": config["ip"],
                    "message": "Bridge unavailable: %s" % exc}
    if command == "set" and len(args) == 5:
        return control(config, *args[1:])
    raise HueError("Invalid Hue command.")


if __name__ == "__main__":
    try:
        print(json.dumps(main(sys.argv[1:]), ensure_ascii=False))
    except (HueError, OSError, ssl.SSLError, json.JSONDecodeError, KeyError, ValueError, http.client.HTTPException) as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False))
        sys.exit(1)
