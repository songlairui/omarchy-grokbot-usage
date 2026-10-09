#!/usr/bin/env python3
"""Grok Bot weekly usage collector for the Omarchy bar widget.

Reads the Cursor desktop sign-in (read-only) from Cursor's state.vscdb and asks
Cursor's dashboard RPC for the Grok Bot ("sand") weekly meter:

  POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus

Also reads Cursor's own included pool (a separate meter, not part of the
sand response) from GetCurrentPeriodUsage: planUsage.autoPercentUsed
("Cursor models" / Auto) and planUsage.apiPercentUsed ("Other models" /
third-party API), with billingCycleStart/End.

Writes two files under $XDG_STATE_HOME/omarchy/grokbot-usage/:
  usage.json    latest record; on failure the last good reading is kept
  history.json  plateau-merged samples per weekly period (for the charts)

The token is only sent to api2.cursor.sh and is never written or printed.
Standard library only.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

API = "https://api2.cursor.sh/aiserver.v1.DashboardService/"
SAND_METHOD = "GetSandUsageStatus"
CURSOR_METHOD = "GetCurrentPeriodUsage"
SERIES_GROKBOT = "grokbot"
SERIES_CURSOR_AUTO = "cursor-auto"
SERIES_CURSOR_API = "cursor-api"
EVENTS_METHOD = "GetAggregatedUsageEvents"
TOKEN_KEY = "cursorAuth/accessToken"
SCHEMA = 1
HISTORY_WEEKS = 12
MAX_POINTS = 4000
DUE_SECONDS_DEFAULT = 240


# ---------------------------------------------------------------- paths / io

def state_dir() -> Path:
  base = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state"))
  path = base / "omarchy" / "grokbot-usage"
  path.mkdir(parents=True, exist_ok=True)
  return path


def cursor_db() -> Path:
  raw = os.environ.get("GROKBOT_USAGE_CURSOR_DB")
  if raw:
    return Path(os.path.expanduser(raw))
  config = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
  return config / "Cursor" / "User" / "globalStorage" / "state.vscdb"


def load_json(path: Path) -> dict[str, Any]:
  try:
    data = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, ValueError):
    return {}
  return data if isinstance(data, dict) else {}


def write_json(path: Path, payload: dict[str, Any]) -> None:
  fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".", suffix=".tmp")
  tmp = Path(tmp_name)
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
      json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
      handle.write("\n")
    tmp.chmod(0o600)
    tmp.replace(path)
  except BaseException:
    tmp.unlink(missing_ok=True)
    raise


# ---------------------------------------------------------------- time utils

def utcnow() -> datetime:
  return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
  return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(value: Any) -> datetime | None:
  text = str(value or "").strip()
  if not text:
    return None
  if text.endswith("Z"):
    text = text[:-1] + "+00:00"
  try:
    dt = datetime.fromisoformat(text)
  except ValueError:
    return None
  if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
  return dt.astimezone(timezone.utc)


# ---------------------------------------------------------------- network

def read_token() -> str:
  db = cursor_db()
  if not db.exists():
    return ""
  try:
    conn = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
  except sqlite3.Error:
    return ""
  try:
    row = conn.execute("SELECT value FROM ItemTable WHERE key = ?", (TOKEN_KEY,)).fetchone()
  except sqlite3.Error:
    return ""
  finally:
    conn.close()
  return str(row[0] or "").strip() if row else ""


class RpcError(Exception):
  def __init__(self, message: str, auth: bool = False):
    super().__init__(message)
    self.auth = auth


def rpc(method: str, token: str, body: dict[str, Any], timeout: float = 15) -> dict[str, Any]:
  request = urllib.request.Request(
    API + method,
    data=json.dumps(body).encode("utf-8"),
    method="POST",
    headers={
      "Authorization": "Bearer " + token,
      "Content-Type": "application/json",
      "Accept": "application/json",
      "Connect-Protocol-Version": "1",
    },
  )
  try:
    with urllib.request.urlopen(request, timeout=timeout) as response:
      raw = response.read() or b"{}"
  except urllib.error.HTTPError as error:
    if error.code in (401, 403):
      raise RpcError("Cursor rejected the saved sign-in. Sign in to Cursor again.", auth=True)
    raise RpcError(f"{method} returned HTTP {error.code}")
  except Exception:
    raise RpcError(f"Couldn't reach api2.cursor.sh ({method})")
  try:
    data = json.loads(raw.decode("utf-8", errors="replace"))
  except ValueError:
    raise RpcError(f"{method} returned invalid JSON")
  if not isinstance(data, dict):
    raise RpcError(f"{method} returned an unexpected payload")
  return data


# ---------------------------------------------------------------- parsing

def parse_sand(payload: dict[str, Any]) -> dict[str, Any]:
  start = parse_iso(payload.get("currentPeriodStart"))
  reset = parse_iso(payload.get("nextResetTimestampUtc"))
  raw = payload.get("usagePercent")
  if raw is None:
    # proto3 omits zero; a live period without a percent is 0% used.
    used = 0.0 if (start or reset) else None
  else:
    try:
      used = max(0.0, min(1.0, float(raw) / 100.0))
    except (TypeError, ValueError):
      used = None
  if used is None:
    raise RpcError("GetSandUsageStatus returned no usage percent")
  on_demand = payload.get("onDemandSettings") if isinstance(payload.get("onDemandSettings"), dict) else {}
  return {
    "used": round(used, 6),
    "periodStart": iso(start) if start else "",
    "resetsAt": iso(reset) if reset else "",
    "planLabel": str(payload.get("grokPlanLabel") or ""),
    "cursorPlan": str(payload.get("cursorPlanName") or ""),
    "billingBrand": str(payload.get("billingBrand") or ""),
    "hasAvailableUsage": bool(payload.get("hasAvailableUsage", used < 1.0)),
    "includedLimitZero": bool(payload.get("includedLimitZero", False)),
    "onDemandEligible": bool(on_demand.get("eligible", False)),
    "dashboardUrl": str(on_demand.get("dashboardUrl") or "https://cursor.com/dashboard/spending"),
  }


def ms_iso(value: Any) -> str:
  try:
    ms = int(str(value).strip())
  except (TypeError, ValueError):
    dt = parse_iso(value)
    return iso(dt) if dt else ""
  if ms < 10**12:
    ms *= 1000
  return iso(datetime.fromtimestamp(ms / 1000, timezone.utc))


def used_ratio(value: Any) -> float | None:
  try:
    n = float(value)
  except (TypeError, ValueError):
    return None
  if n != n:
    return None
  return max(0.0, min(1.0, n / 100.0))


def parse_cursor(payload: dict[str, Any]) -> dict[str, Any]:
  bucket = payload.get("planUsage") if isinstance(payload.get("planUsage"), dict) else {}
  auto = used_ratio(bucket.get("autoPercentUsed"))
  api = used_ratio(bucket.get("apiPercentUsed"))
  if auto is None and api is None:
    raise RpcError("GetCurrentPeriodUsage returned no plan usage")
  return {
    "autoUsed": round(auto, 6) if auto is not None else None,
    "apiUsed": round(api, 6) if api is not None else None,
    "periodStart": ms_iso(payload.get("billingCycleStart")),
    "resetsAt": ms_iso(payload.get("billingCycleEnd")),
    "displayMessage": str(payload.get("displayMessage") or ""),
  }


def fetch_categories(token: str, start: datetime | None, end: datetime) -> list[dict[str, Any]]:
  """grok-bot-* rows from Cursor's usage events for the current period.

  Cursor has been moving these rows out of the Cursor breakdown, so an empty
  list is normal; the popup only renders the section when rows exist."""
  if start is None:
    start = end - timedelta(days=7)
  body = {
    "teamId": -1,
    "startDate": str(int(start.timestamp() * 1000)),
    "endDate": str(int(end.timestamp() * 1000)),
  }
  try:
    data = rpc(EVENTS_METHOD, token, body, timeout=15)
  except RpcError:
    return []
  rows = []
  for entry in data.get("aggregations") or []:
    if not isinstance(entry, dict):
      continue
    intent = str(entry.get("modelIntent") or "")
    if not intent.startswith("grok-bot"):
      continue
    tokens = 0
    for key in ("inputTokens", "outputTokens", "cacheWriteTokens", "cacheReadTokens"):
      try:
        tokens += int(entry.get(key) or 0)
      except (TypeError, ValueError):
        pass
    try:
      cents = float(entry.get("totalCents") or 0)
    except (TypeError, ValueError):
      cents = 0.0
    rows.append({"id": intent, "tokens": tokens, "cents": round(cents, 4)})
  rows.sort(key=lambda r: (-r["cents"], -r["tokens"]))
  return rows


# ---------------------------------------------------------------- history

def period_key(sample: dict[str, Any]) -> str:
  return str(sample.get("resetsAt") or sample.get("periodStart") or "")


def series_of(point: dict[str, Any]) -> str:
  return str(point.get("series") or SERIES_GROKBOT)


def merge_sample(points: list[dict[str, Any]], series: str, used: float,
                 period_start: str, resets_at: str, now: datetime) -> list[dict[str, Any]]:
  now_iso = iso(now)
  sample = {
    "series": series,
    "t": now_iso,
    "until": now_iso,
    "used": round(float(used), 4),
    "periodStart": period_start or "",
    "resetsAt": resets_at or "",
  }
  for last in reversed(points):
    if series_of(last) != series:
      continue
    if period_key(last) == period_key(sample) and abs(float(last.get("used", -1)) - sample["used"]) < 1e-4:
      last["until"] = now_iso
      return points
    break
  points.append(sample)
  return points


def trim(points: list[dict[str, Any]], now: datetime, weeks: int = HISTORY_WEEKS) -> list[dict[str, Any]]:
  cutoff = now - timedelta(weeks=weeks)
  kept = []
  for point in points:
    t = parse_iso(point.get("until") or point.get("t"))
    if t is None or t < cutoff:
      continue
    kept.append(point)
  return kept[-MAX_POINTS:]


def update_history(samples: list[tuple[str, float, str, str]], now: datetime) -> None:
  path = state_dir() / "history.json"
  lock_path = state_dir() / ".history.lock"
  with open(lock_path, "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    data = load_json(path)
    points = data.get("points") if isinstance(data.get("points"), list) else []
    points = [p for p in points if isinstance(p, dict)]
    for series, used, start, reset in samples:
      points = merge_sample(points, series, used, start, reset, now)
    points = trim(points, now)
    write_json(path, {"schemaVersion": SCHEMA, "updatedAt": iso(now), "points": points})


# ---------------------------------------------------------------- main

def collect(force: bool, due_seconds: int) -> dict[str, Any]:
  path = state_dir() / "usage.json"
  previous = load_json(path)
  now = utcnow()

  fetched = parse_iso(previous.get("fetchedAt"))
  if not force and previous.get("ok") and fetched and (now - fetched).total_seconds() < due_seconds:
    return previous

  record: dict[str, Any] = {
    "schemaVersion": SCHEMA,
    "ok": False,
    "attemptedAt": iso(now),
    "fetchedAt": previous.get("fetchedAt") or "",
    "usage": previous.get("usage") if isinstance(previous.get("usage"), dict) else None,
    "categories": previous.get("categories") if isinstance(previous.get("categories"), list) else [],
    "cursor": previous.get("cursor") if isinstance(previous.get("cursor"), dict) else None,
    "cursorError": "",
    "error": "",
    "authProblem": False,
  }

  token = read_token()
  if not token:
    record["error"] = "No Cursor sign-in found. Open Cursor and sign in."
    record["authProblem"] = True
    write_json(path, record)
    return record

  try:
    usage = parse_sand(rpc(SAND_METHOD, token, {}))
  except RpcError as error:
    record["error"] = str(error)
    record["authProblem"] = error.auth
    write_json(path, record)
    return record

  record.update({"ok": True, "fetchedAt": iso(now), "usage": usage, "error": ""})
  samples = [(SERIES_GROKBOT, usage["used"], usage.get("periodStart", ""), usage.get("resetsAt", ""))]
  try:
    cursor = parse_cursor(rpc(CURSOR_METHOD, token, {}))
    cursor["fetchedAt"] = iso(now)
    record["cursor"] = cursor
    for series, key in ((SERIES_CURSOR_AUTO, "autoUsed"), (SERIES_CURSOR_API, "apiUsed")):
      if cursor.get(key) is not None:
        samples.append((series, cursor[key], cursor["periodStart"], cursor["resetsAt"]))
  except RpcError as error:
    record["cursorError"] = str(error)  # keep the previous cursor reading
  record["categories"] = fetch_categories(token, parse_iso(usage.get("periodStart")), now)
  write_json(path, record)
  try:
    update_history(samples, now)
  except OSError as error:
    print(f"grokbot-usage: history write failed ({error})", file=sys.stderr)
  return record


def main() -> int:
  parser = argparse.ArgumentParser(description="Collect Grok Bot weekly usage")
  parser.add_argument("--force", action="store_true", help="ignore the reuse window")
  parser.add_argument("--due", type=int, default=DUE_SECONDS_DEFAULT,
                      help="reuse the last good reading if younger than this many seconds")
  parser.add_argument("--print", action="store_true", help="print the record (no token is ever included)")
  args = parser.parse_args()
  record = collect(args.force, max(0, args.due))
  if args.print:
    print(json.dumps(record, indent=2, sort_keys=True))
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
