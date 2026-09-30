import sys
from pathlib import Path
import unittest
import tempfile
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
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.favorites_patch = patch("hue.FAVORITES", Path(self.directory.name) / "favorites.json")
        self.favorites_patch.start()
        self.addCleanup(self.favorites_patch.stop)

    def scene_sample(self):
        return sample() + [
            {"type": "bridge", "id": "bridge-resource", "bridge_id": "bridge-one"},
            {"type": "scene", "id": "scene-a", "metadata": {"name": "Evening"},
             "group": {"rid": "zone-a", "rtype": "zone"}, "status": {"active": "static"}},
            {"type": "scene", "id": "scene-orphan", "group": {"rid": "missing", "rtype": "room"}},
        ]

    def test_scenes_are_associated_with_their_groups(self):
        view = hue.snapshot(self.scene_sample())
        self.assertEqual(len(view["scenes"]), 1)
        self.assertEqual(view["scenes"][0]["groupName"], "Corner")
        self.assertEqual(view["scenes"][0]["active"], "static")

    @patch("hue.resource_id", side_effect=lambda value: value)
    @patch("hue.request")
    @patch("hue.resources")
    def test_scene_recall_and_failed_followup(self, resources, request, resource_id):
        resources.side_effect = [self.scene_sample(), TimeoutError("offline")]
        result = hue.recall({}, "scene-a")
        self.assertTrue(result["applied"])
        self.assertIn("accepted", result["warning"])
        self.assertEqual(request.call_args.args[2:], ("/clip/v2/resource/scene/scene-a", {"recall": {"action": "active"}}))

    @patch("hue.resources")
    def test_favorites_are_persistent_idempotent_and_bridge_specific(self, resources):
        resources.return_value = self.scene_sample()
        hue.favorite({}, "scene", "scene-a", "true")
        hue.favorite({}, "scene", "scene-a", "true")
        self.assertEqual(len(hue.favorite_entries("bridge-one")), 1)
        self.assertEqual(hue.favorite_entries("bridge-two"), [])
        self.assertEqual(hue.FAVORITES.stat().st_mode & 0o777, 0o600)
        hue.favorite({}, "scene", "scene-a", "false")
        self.assertEqual(hue.favorite_entries("bridge-one"), [])

    @patch("hue.request")
    @patch("hue.resources")
    def test_deleted_scene_is_not_recalled(self, resources, request):
        resources.return_value = self.scene_sample()
        with self.assertRaises(hue.HueError):
            hue.recall({}, "missing")
        request.assert_not_called()

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
        self.assertEqual(writes[0].args[3]["dimming"]["brightness"], 100)

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
        self.assertEqual(writes[0].args[3]["dimming"]["brightness"], 100)

    def test_color_and_brightness_validation(self):
        with self.assertRaises(hue.HueError):
            hue.rgb_xy("#not-a-color")
        with self.assertRaises(hue.HueError):
            hue.rgb_xy("#000000")
        self.assertGreater(hue.rgb_xy("#ff0000")["x"], 0.6)
        self.assertEqual(hue.color_brightness("#800000"), 50.2)
        self.assertEqual(hue.color_brightness("#010000"), 1)

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

    @patch("hue.save")
    @patch("hue.resources", side_effect=hue.HueAuthError("HTTP 403"))
    @patch("hue.load")
    def test_rejected_access_does_not_delete_application_key(self, load, resources, save):
        config = {"ip": "192.168.1.2", "key": "existing-key", "fingerprint": "pin"}
        load.return_value = config
        result = hue.main(["status"])
        self.assertTrue(result["authError"])
        self.assertTrue(result["trusted"])
        self.assertFalse(result["paired"])
        self.assertEqual(config["key"], "existing-key")
        save.assert_not_called()

    @patch("hue.resources")
    @patch("hue.load", return_value={"ip": "192.168.1.2", "key": "key", "fingerprint": "pin"})
    def test_status_marks_network_and_certificate_failures_offline(self, load, resources):
        for error in (TimeoutError("timed out"), hue.HueCertificateError("certificate changed")):
            with self.subTest(error=error):
                resources.side_effect = error
                result = hue.main(["status"])
                self.assertTrue(result["paired"])
                self.assertTrue(result["offline"])
                self.assertIn(str(error), result["message"])

    @patch("hue.PinnedConnection")
    def test_pairing_request_does_not_send_old_application_key(self, connection):
        connection.return_value.getresponse.return_value.status = 200
        connection.return_value.getresponse.return_value.read.return_value = b'[{"success":{"username":"new-key"}}]'
        result = hue.request({"ip": "192.168.1.2", "key": "old-key", "fingerprint": "pin"},
                             "POST", "/api", {"devicetype": "omarchy_hue#laptop"})
        self.assertEqual(result[0]["success"]["username"], "new-key")
        self.assertNotIn("hue-application-key", connection.return_value.request.call_args.kwargs["headers"])

    @patch("hue.resource_id", side_effect=lambda value: value)
    @patch("hue.request", return_value={"data": []})
    @patch("hue.resources", side_effect=[sample(), TimeoutError("timed out")])
    def test_successful_put_is_reported_when_followup_get_fails(self, resources, request, resource_id):
        result = hue.control({"ip": "192.168.1.2", "key": "key", "fingerprint": "pin"},
                             "light", "light-a", "on", "true")
        self.assertTrue(result["applied"])
        self.assertNotIn("state", result)
        self.assertIn("accepted the change", result["warning"])
        self.assertEqual(request.call_count, 1)

    @patch("hue.time.sleep")
    @patch("hue.resource_id", side_effect=lambda value: value)
    @patch("hue.request")
    @patch("hue.resources")
    def test_partial_color_write_reports_accepted_lights(self, resources, request, resource_id, sleep):
        items = sample() + [{"type": "light", "id": "light-c", "owner": {"rid": "device-a"},
                             "on": {"on": True}, "color": {"xy": {"x": 0.4, "y": 0.3}}}]
        resources.return_value = items
        def write(config, method, path, payload):
            if path.endswith("light-c"):
                raise TimeoutError("light unreachable")
            return {"data": []}
        request.side_effect = write
        result = hue.control({"ip": "192.168.1.2", "key": "key", "fingerprint": "pin"},
                             "group", "room-a", "color", "#ff0000")
        self.assertTrue(result["applied"])
        self.assertIn("1 of 2 lights", result["warning"])
        self.assertIn("light unreachable", result["warning"])

    @patch("hue.request", return_value={"data": {"unexpected": "object"}})
    def test_invalid_resource_list_is_not_treated_as_empty_bridge(self, request):
        with self.assertRaisesRegex(hue.HueError, "invalid resource list"):
            hue.resources({"ip": "192.168.1.2", "key": "key", "fingerprint": "pin"})


if __name__ == "__main__":
    unittest.main()
