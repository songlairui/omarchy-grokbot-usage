import importlib.util
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("collect", ROOT / "collect.py")
collect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collect)


class ParseSand(unittest.TestCase):
  def test_real_shape(self):
    usage = collect.parse_sand({
      "currentPeriodStart": "2026-10-07T00:13:32.413Z",
      "nextResetTimestampUtc": "2026-10-14T00:13:32.413Z",
      "usagePercent": 24.417194,
      "hasAvailableUsage": True,
      "hasNonZeroIncludedLimit": True,
      "onDemandSettings": {"visible": True, "eligible": True, "dashboardUrl": "https://cursor.com/dashboard/spending"},
      "grokPlanLabel": "Grok Bot Plan",
      "cursorPlanName": "Ultra",
      "billingBrand": "SAND_BILLING_BRAND_CURSOR",
    })
    self.assertAlmostEqual(usage["used"], 0.244172, places=5)
    self.assertEqual(usage["resetsAt"], "2026-10-14T00:13:32Z")
    self.assertEqual(usage["periodStart"], "2026-10-07T00:13:32Z")
    self.assertEqual(usage["planLabel"], "Grok Bot Plan")

  def test_zero_omitted(self):
    usage = collect.parse_sand({"nextResetTimestampUtc": "2026-10-14T00:00:00Z"})
    self.assertEqual(usage["used"], 0.0)

  def test_no_period_no_percent(self):
    with self.assertRaises(collect.RpcError):
      collect.parse_sand({})


class ParseCursor(unittest.TestCase):
  def test_real_shape(self):
    c = collect.parse_cursor({
      "billingCycleStart": "1789171914000",
      "billingCycleEnd": "1791763914000",
      "planUsage": {"autoPercentUsed": 78.57633333333334, "apiPercentUsed": 100, "totalPercentUsed": 79.2},
    })
    self.assertAlmostEqual(c["autoUsed"], 0.785763, places=5)
    self.assertEqual(c["apiUsed"], 1.0)
    self.assertTrue(c["periodStart"].startswith("2026-09-"))
    self.assertTrue(c["resetsAt"].startswith("2026-10-"))

  def test_missing(self):
    with self.assertRaises(collect.RpcError):
      collect.parse_cursor({"planUsage": {}})


class History(unittest.TestCase):
  def merge(self, pts, used, at, reset="2026-10-14T00:00:00Z", series="grokbot"):
    return collect.merge_sample(pts, series, used, "2026-10-07T00:00:00Z", reset, at)

  def test_plateau_merge_and_step(self):
    t0 = datetime(2026, 10, 8, tzinfo=timezone.utc)
    pts = self.merge([], 0.1, t0)
    pts = self.merge(pts, 0.1, t0 + timedelta(minutes=5))
    self.assertEqual(len(pts), 1)
    self.assertEqual(pts[0]["until"], "2026-10-08T00:05:00Z")
    pts = self.merge(pts, 0.2, t0 + timedelta(minutes=10))
    self.assertEqual(len(pts), 2)
    pts = self.merge(pts, 0.2, t0 + timedelta(minutes=15), reset="2026-10-21T00:00:00Z")
    self.assertEqual(len(pts), 3)

  def test_series_are_independent(self):
    t0 = datetime(2026, 10, 8, tzinfo=timezone.utc)
    pts = self.merge([], 0.1, t0)
    pts = self.merge(pts, 0.5, t0, series="cursor-auto")
    pts = self.merge(pts, 0.1, t0 + timedelta(minutes=5))
    pts = self.merge(pts, 0.5, t0 + timedelta(minutes=5), series="cursor-auto")
    self.assertEqual(len(pts), 2)
    self.assertEqual(pts[1]["until"], "2026-10-08T00:05:00Z")
    legacy = [{"t": "2026-10-08T00:00:00Z", "until": "2026-10-08T00:00:00Z", "used": 0.1,
               "periodStart": "2026-10-07T00:00:00Z", "resetsAt": "2026-10-14T00:00:00Z"}]
    self.assertEqual(len(self.merge(legacy, 0.1, t0 + timedelta(minutes=9))), 1)

  def test_trim(self):
    now = datetime(2026, 10, 8, tzinfo=timezone.utc)
    old = {"t": "2026-06-01T00:00:00Z", "until": "2026-06-01T00:00:00Z", "used": 0.5}
    new = {"t": "2026-10-07T00:00:00Z", "until": "2026-10-07T00:00:00Z", "used": 0.5}
    self.assertEqual(collect.trim([old, new], now), [new])


class KeepLastGood(unittest.TestCase):
  def test_failure_keeps_usage(self):
    with tempfile.TemporaryDirectory() as tmp:
      os.environ["XDG_STATE_HOME"] = tmp
      os.environ["GROKBOT_USAGE_CURSOR_DB"] = str(Path(tmp) / "missing.vscdb")
      path = collect.state_dir() / "usage.json"
      collect.write_json(path, {"ok": True, "fetchedAt": "2026-10-08T00:00:00Z", "usage": self.good()})
      record = collect.collect(force=True, due_seconds=0)
      self.assertFalse(record["ok"])
      self.assertEqual(record["usage"]["used"], 0.3)
      self.assertTrue(record["authProblem"])

  @staticmethod
  def good():
    return {"used": 0.3, "periodStart": "2026-10-07T00:00:00Z", "resetsAt": "2026-10-14T00:00:00Z"}


if __name__ == "__main__":
  unittest.main()
