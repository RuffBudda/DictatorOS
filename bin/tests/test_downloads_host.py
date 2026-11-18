import importlib.machinery, importlib.util, io, os, unittest

_path = os.path.join(os.path.dirname(__file__), "..", "downloads-host")
_loader = importlib.machinery.SourceFileLoader("downloads_host", _path)
_spec = importlib.util.spec_from_loader("downloads_host", _loader)
dh = importlib.util.module_from_spec(_spec)
_loader.exec_module(dh)


def item(i, state, error=""):
    return {"id": i, "name": f"f{i}", "path": f"/tmp/f{i}", "state": state, "error": error}


class Framing(unittest.TestCase):
    def test_round_trip(self):
        buf = io.BytesIO()
        dh.write_message(buf, {"a": "é", "n": 1})
        buf.seek(0)
        self.assertEqual(dh.read_message(buf), {"a": "é", "n": 1})
        self.assertIsNone(dh.read_message(buf))  # EOF

    def test_truncated_is_eof(self):
        self.assertIsNone(dh.read_message(io.BytesIO(b"\x05\x00")))


class Validate(unittest.TestCase):
    def test_unknown_action(self):
        self.assertFalse(dh.validate_command({"action": "rm", "id": 1})[0])

    def test_id_must_be_int(self):
        self.assertFalse(dh.validate_command({"action": "pause", "id": "1"})[0])
        self.assertFalse(dh.validate_command({"action": "pause", "id": True})[0])
        self.assertFalse(dh.validate_command({"action": "open"})[0])

    def test_ok(self):
        self.assertTrue(dh.validate_command({"action": "cancel", "id": 3})[0])
        self.assertTrue(dh.validate_command({"action": "clear"})[0])

    def test_not_a_dict(self):
        self.assertFalse(dh.validate_command(["pause", 1])[0])


class Transitions(unittest.TestCase):
    def test_complete_only_after_in_progress(self):
        prev = {1: "in_progress"}
        out = dh.transitions(prev, [item(1, "complete"), item(2, "complete")])
        self.assertEqual([(k, d["id"]) for k, d in out], [("complete", 1)])

    def test_failed_but_not_cancelled(self):
        prev = {1: "in_progress", 2: "in_progress"}
        out = dh.transitions(prev, [item(1, "interrupted", "NETWORK_FAILED"),
                                    item(2, "interrupted", "USER_CANCELED")])
        self.assertEqual([(k, d["id"]) for k, d in out], [("failed", 1)])

    def test_still_running_nothing(self):
        self.assertEqual(dh.transitions({1: "in_progress"}, [item(1, "in_progress")]), [])


class Clear(unittest.TestCase):
    def test_clears_finished_keeps_running(self):
        cleared = dh.apply_clear([item(1, "in_progress"), item(2, "complete"), item(3, "interrupted")], {9})
        self.assertEqual(cleared, {2, 3, 9})

    def test_visible_filters_cleared(self):
        self.assertEqual([d["id"] for d in dh.visible([item(1, "complete"), item(2, "complete")], {1})], [2])


if __name__ == "__main__":
    unittest.main()
