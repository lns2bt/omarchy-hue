import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hue


def sample():
    return [
        {"type": "device", "id": "device-a", "metadata": {"name": "Desk"}},
        {"type": "device", "id": "device-b", "metadata": {"name": "Ceiling"}},
        {"type": "light", "id": "light-a", "owner": {"rid": "device-a"},
         "on": {"on": True}, "dimming": {"brightness": 65}, "color": {"xy": {"x": 0.4, "y": 0.3}}},
        {"type": "light", "id": "light-b", "owner": {"rid": "device-b"},
         "on": {"on": False}, "dimming": {"brightness": 30}},
        {"type": "room", "id": "room-a", "metadata": {"name": "Living room"},
         "children": [{"rid": "device-a", "rtype": "device"}, {"rid": "device-b", "rtype": "device"}],
         "services": [{"rid": "group-room", "rtype": "grouped_light"}]},
        {"type": "zone", "id": "zone-a", "metadata": {"name": "Corner"},
         "children": [{"rid": "light-a", "rtype": "light"}],
         "services": [{"rid": "group-zone", "rtype": "grouped_light"}]},
        {"type": "grouped_light", "id": "group-room", "on": {"on": True}},
        {"type": "grouped_light", "id": "group-zone", "on": {"on": True}},
        {"type": "bridge_home", "id": "home", "services": [{"rid": "group-home", "rtype": "grouped_light"}]},
        {"type": "grouped_light", "id": "group-home", "on": {"on": True}},
    ]


class HueTests(unittest.TestCase):
    def test_snapshot_rooms_zones_and_lights(self):
        view = hue.snapshot(sample())
        self.assertEqual([g["kind"] for g in view["groups"]], ["Room", "Zone"])
        self.assertEqual([l["name"] for l in view["lights"]], ["Ceiling", "Desk"])
        self.assertTrue(view["groups"][0]["color"])
        self.assertFalse(view["lights"][0]["color"])
        self.assertEqual(view["home"], "group-home")

    @patch("hue.time.sleep")
    @patch("hue.resource_id", side_effect=lambda value: value)
    @patch("hue.request")
    def test_group_color_only_targets_color_capable_members(self, request, resource_id, sleep):
        request.side_effect = lambda config, method, path, body=None: (
            {"data": sample()} if method == "GET" else {"data": []})
        hue.control({"ip": "192.168.1.2", "key": "key", "fingerprint": "x"},
                    "group", "room-a", "color", "#ff0000")
        writes = [c for c in request.call_args_list if c.args[1] == "PUT"]
        self.assertEqual(len(writes), 1)
        self.assertTrue(writes[0].args[2].endswith("/light/light-a"))

    @patch("hue.resource_id", side_effect=lambda value: value)
    @patch("hue.request")
    def test_color_room_with_only_color_lights_uses_grouped_write(self, request, resource_id):
        items = [item for item in sample() if item.get("id") != "light-b"]
        request.side_effect = lambda config, method, path, body=None: (
            {"data": items} if method == "GET" else {"data": []})
        hue.control({"ip": "192.168.1.2", "key": "key", "fingerprint": "x"},
                    "group", "room-a", "color", "#ff0000")
        writes = [c for c in request.call_args_list if c.args[1] == "PUT"]
        self.assertEqual(len(writes), 1)
        self.assertTrue(writes[0].args[2].endswith("/grouped_light/group-room"))
        self.assertEqual(writes[0].args[3]["color"]["xy"], hue.rgb_xy("#ff0000"))

    def test_color_and_brightness_validation(self):
        with self.assertRaises(hue.HueError):
            hue.rgb_xy("#not-a-color")
        with self.assertRaises(hue.HueError):
            hue.rgb_xy("#000000")
        self.assertGreater(hue.rgb_xy("#ff0000")["x"], 0.6)

    @patch("hue.resource_id", side_effect=lambda value: value)
    @patch("hue.request")
    def test_all_uses_home_service_and_room_uses_group_service(self, request, resource_id):
        request.side_effect = lambda config, method, path, body=None: (
            {"data": sample()} if method == "GET" else {"data": []})
        config = {"ip": "192.168.1.2", "key": "key", "fingerprint": "x"}
        hue.control(config, "all", "home", "on", "false")
        hue.control(config, "group", "room-a", "brightness", "42")
        writes = [c for c in request.call_args_list if c.args[1] == "PUT"]
        self.assertTrue(writes[0].args[2].endswith("/grouped_light/group-home"))
        self.assertEqual(writes[0].args[3], {"on": {"on": False}})
        self.assertTrue(writes[1].args[2].endswith("/grouped_light/group-room"))
        self.assertEqual(writes[1].args[3]["dimming"]["brightness"], 42)


if __name__ == "__main__":
    unittest.main()
