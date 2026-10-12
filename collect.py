#!/usr/bin/env python3
"""Grok Bot weekly usage collector for the Omarchy bar widget.

Reads the Cursor desktop sign-in (read-only) from Cursor's state.vscdb and asks
Cursor's dashboard RPC for the Grok Bot ("sand") weekly meter:

  POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus

Also reads Cursor's own included pool (a separate meter, not part of the
sand response) from GetCurrentPeriodUsage: planUsage.autoPercentUsed
("Cursor models" / Auto) and planUsage.apiPercentUsed ("Other models" /
third-party API), with billingCycleStart/End.

SuperGrok weekly leftover comes from GET cli-chat-proxy.grok.com billing,
using the grok.com OIDC session in ~/.grok/auth.json.

Writes two files under $XDG_STATE_HOME/omarchy/grokbot-usage/:
  usage.json    schemaVersion 2; sections sand, cursor, supergrok, app, update
  history.json  plateau-merged samples per weekly period (for the charts)

Tokens are only sent over HTTPS to the pinned host (redirects are never
followed) and are never written or printed.
Standard library only.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
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
SERIES_SUPERGROK = "supergrok"
EVENTS_METHOD = "GetAggregatedUsageEvents"
TOKEN_KEY = "cursorAuth/accessToken"
SCHEMA = 2
HISTORY_SCHEMA = 1
HISTORY_WEEKS = 12
MAX_POINTS = 4000
DUE_SECONDS_DEFAULT = 240
UPDATE_FEED = "https://api2.cursor.sh/updates/api/update/linux-x64/sand/{installed}/omarchy-bar/stable"
UPDATE_DUE_SECONDS = 6 * 3600
DOWNLOAD_HOST = "downloads.cursor.com"
SUPERGROK_BILLING = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
SUPERGROK_SETTINGS = "https://cli-chat-proxy.grok.com/v1/settings"
SUPERGROK_HOST = "cli-chat-proxy.grok.com"
SUPERGROK_TOKEN_AUTH = "xai-grok-cli"
SUPERGROK_TIER_NAMES = {5: "SuperGrok Heavy", 4: "SuperGrok Plus", 3: "SuperGrok"}
PACMAN_LOCAL = Path(os.environ.get("GROKBOT_PACMAN_LOCAL") or "/var/lib/pacman/local")
APP_NAME = "grok-bot"
SECTIONS = ("sand", "cursor", "supergrok", "app", "update")


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


def grok_home() -> Path:
  raw = os.environ.get("GROK_HOME")
  if raw:
    return Path(os.path.expandvars(os.path.expanduser(raw)))
  return Path.home() / ".grok"


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


API_SCHEME = "https"
API_DOMAIN = "cursor.sh"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
  """Never follow redirects: the request may carry a token, so a 3xx
  must not forward it to another origin (or to plain HTTP)."""

  def redirect_request(self, req, fp, code, msg, headers, newurl):
    raise urllib.error.HTTPError(req.full_url, code, f"redirect refused ({code})", headers, fp)


_OPENER = urllib.request.build_opener(_NoRedirect)


def checked_url(url: str, allowed_host: str) -> str:
  parts = urllib.parse.urlsplit(url)
  host = (parts.hostname or "").lower()
  allowed = allowed_host.lower()
  host_ok = host == allowed or host.endswith("." + allowed)
  if parts.scheme != API_SCHEME or not host_ok or parts.port not in (None, 443) \
      or parts.username or parts.password:
    raise RpcError(f"refusing to send a request to {parts.scheme}://{parts.netloc}")
  return url


def api_url(method: str) -> str:
  return checked_url(API + method, API_DOMAIN)


def rpc(method: str, token: str, body: dict[str, Any], timeout: float = 15) -> dict[str, Any]:
  url = api_url(method)
  request = urllib.request.Request(
    url,
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
    with _OPENER.open(request, timeout=timeout) as response:
      raw = response.read() or b"{}"
  except urllib.error.HTTPError as error:
    if error.code in (401, 403):
      raise RpcError("Cursor rejected the saved sign-in. Sign in to Cursor again.", auth=True)
    if 300 <= error.code < 400:
      raise RpcError(f"{method} answered with a redirect ({error.code}); not following it")
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


def parse_supergrok(payload: dict[str, Any]) -> dict[str, Any]:
  config = payload.get("config") if isinstance(payload.get("config"), dict) else {}
  if not config and any(k in payload for k in ("creditUsagePercent", "currentPeriod", "billingPeriodEnd")):
    config = payload
  period = config.get("currentPeriod") if isinstance(config.get("currentPeriod"), dict) else {}
  start = parse_iso(period.get("start") or config.get("billingPeriodStart"))
  reset = parse_iso(period.get("end") or config.get("billingPeriodEnd"))
  raw = config.get("creditUsagePercent")
  if raw is None:
    used = 0.0 if (period or reset or start) else None
  else:
    try:
      used = max(0.0, min(1.0, float(raw) / 100.0))
    except (TypeError, ValueError):
      used = None
  if used is None:
    raise RpcError("Grok billing returned no usage percent")
  return {
    "used": round(used, 6),
    "periodStart": iso(start) if start else "",
    "resetsAt": iso(reset) if reset else "",
    "tierLabel": tier_label(payload, config),
  }


def named_tier(value: Any) -> str:
  text = str(value or "").strip()
  if text and not text.isdigit():
    return text
  try:
    number = int(text) if text else None
  except (TypeError, ValueError):
    number = None
  return SUPERGROK_TIER_NAMES.get(number, "") if number is not None else ""


def tier_label(payload: dict[str, Any], config: dict[str, Any] | None = None) -> str:
  sources = [payload]
  if isinstance(config, dict):
    sources.append(config)
  for source in sources:
    for key in ("subscription_tier_display", "subscriptionTierDisplay", "subscriptionTier", "subscription_tier", "tier"):
      label = named_tier(source.get(key))
      if label:
        return label
  return ""


def jwt_tier_label(token: str) -> str:
  try:
    import base64
    part = token.split(".")[1]
    part += "=" * ((4 - len(part) % 4) % 4)
    data = json.loads(base64.urlsafe_b64decode(part.encode("ascii")))
  except Exception:
    return ""
  if not isinstance(data, dict):
    return ""
  return named_tier(data.get("tier"))


def settings_tier_label(login: dict[str, str]) -> str:
  try:
    request = urllib.request.Request(
      checked_url(SUPERGROK_SETTINGS, SUPERGROK_HOST),
      method="GET",
      headers={
        "Authorization": "Bearer " + login["key"],
        "X-XAI-Token-Auth": SUPERGROK_TOKEN_AUTH,
        "x-userid": login.get("user_id") or "",
        "Accept": "application/json",
      },
    )
    with _OPENER.open(request, timeout=10) as response:
      data = json.loads(response.read().decode("utf-8", errors="replace"))
  except Exception:
    return ""
  if not isinstance(data, dict):
    return ""
  return tier_label(data)


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


# ---------------------------------------------------------------- versions / process

def parse_version(text: str) -> tuple[int, ...] | None:
  core = str(text or "").strip().split("-", 1)[0]
  if not core:
    return None
  parts: list[int] = []
  for bit in core.split("."):
    digits = ""
    for ch in bit:
      if ch.isdigit():
        digits += ch
      else:
        break
    if not digits:
      break
    parts.append(int(digits))
  return tuple(parts) if parts else None


def version_newer(candidate: str, installed: str) -> bool:
  left = parse_version(candidate)
  right = parse_version(installed)
  if left is None or right is None:
    return False
  width = max(len(left), len(right))
  left = left + (0,) * (width - len(left))
  right = right + (0,) * (width - len(right))
  return left > right


def parse_checkupdates(text: str, package: str = APP_NAME) -> str:
  """Version checkupdates would install, without the pkgrel.

  Omarchy's update icon uses the same command, via omarchy-update-available.
  A line looks like `grok-bot 0.29.0-1 -> 0.70.2-1`.
  """
  for line in text.splitlines():
    parts = line.split()
    if len(parts) >= 4 and parts[0] == package and parts[-2] == "->":
      version = parts[-1]
      return version.rsplit("-", 1)[0] if "-" in version else version
  return ""


def fetch_checkupdates(package: str = APP_NAME) -> str:
  try:
    proc = subprocess.run(
      ["checkupdates", "--nocolor"],
      capture_output=True, text=True, timeout=40, check=False,
    )
  except (OSError, subprocess.TimeoutExpired):
    return ""
  return parse_checkupdates(proc.stdout or "", package)


def apply_repo_update(section: dict[str, Any], installed: str, repo_version: str) -> dict[str, Any]:
  out = dict(section)
  if not repo_version or not installed or not version_newer(repo_version, installed):
    return out
  feed = str(out.get("latest") or "")
  if not feed or version_newer(repo_version, feed):
    out["latest"] = repo_version
    out["url"] = ""
    out["source"] = "omarchy"
  out["available"] = True
  out["installed"] = installed
  return out


def parse_pacman_desc(path: Path) -> tuple[str, str]:
  try:
    text = path.read_text(encoding="utf-8")
  except OSError:
    return "", ""
  name = ""
  version = ""
  section = ""
  for line in text.splitlines():
    if line.startswith("%") and line.endswith("%"):
      section = line
      continue
    value = line.strip()
    if not value:
      continue
    if section == "%NAME%":
      name = value
      section = ""
    elif section == "%VERSION%":
      version = value.rsplit("-", 1)[0] if "-" in value else value
      section = ""
  return name, version


def installed_version(local_db: Path | None = None) -> str:
  root = local_db if local_db is not None else PACMAN_LOCAL
  if not root.is_dir():
    return ""
  try:
    descs = sorted(root.glob("grok-bot-*/desc"))
  except OSError:
    return ""
  for desc in descs:
    name, version = parse_pacman_desc(desc)
    if name == APP_NAME and version:
      return version
  return ""


def main_grok_bot(cmdline: bytes) -> bool:
  """True for the Grok Bot browser process, false for its helpers.

  Electron rewrites /proc/pid/cmdline into one space-separated string, so
  --type= is not always its own argv element. A normal NUL-separated cmdline
  is handled by flattening first.
  """
  text = cmdline.replace(b"\0", b" ").decode("utf-8", "replace").strip()
  marker = APP_NAME
  start = 0
  while True:
    index = text.find(marker, start)
    if index < 0:
      return False
    before = index == 0 or text[index - 1] == "/"
    after = index + len(marker)
    ended = after == len(text) or text[after] in " \t"
    if before and ended:
      rest = text[after:].strip()
      return "--type=" not in rest
    start = index + 1


def find_main_process(proc: Path = Path("/proc")) -> int | None:
  try:
    entries = list(proc.iterdir())
  except OSError:
    return None
  for entry in entries:
    if not entry.name.isdigit():
      continue
    try:
      raw = (entry / "cmdline").read_bytes()
    except OSError:
      continue
    if raw and main_grok_bot(raw):
      return int(entry.name)
  return None


# ---------------------------------------------------------------- probe envelope / record

def section_reading(section: dict[str, Any]) -> Any:
  if section.get("used") is not None:
    return section.get("used")
  if section.get("autoUsed") is not None or section.get("apiUsed") is not None:
    return section.get("autoUsed") if section.get("autoUsed") is not None else section.get("apiUsed")
  return None


def probe_state(section: dict[str, Any] | None) -> str:
  data = section if isinstance(section, dict) else {}
  if data.get("authProblem"):
    return "signed-out"
  reading = section_reading(data)
  if reading is not None and data.get("ok"):
    return "live"
  if reading is not None and not data.get("ok"):
    return "stale"
  return "empty"


def with_state(section: dict[str, Any]) -> dict[str, Any]:
  out = dict(section)
  out["state"] = probe_state(out)
  return out


def classify(record: dict[str, Any] | None) -> dict[str, bool]:
  data = record if isinstance(record, dict) else {}
  sand = data.get("sand") if isinstance(data.get("sand"), dict) else {}
  app = data.get("app") if isinstance(data.get("app"), dict) else None
  update = data.get("update") if isinstance(data.get("update"), dict) else {}
  state = str(sand.get("state") or probe_state(sand))
  return {
    "signedOut": state == "signed-out",
    "stale": state == "stale",
    "appOffline": app is not None and app.get("running") is False,
    "updateAvailable": update.get("available") is True,
  }


def empty_probe() -> dict[str, Any]:
  return {
    "ok": False,
    "attemptedAt": "",
    "fetchedAt": "",
    "authProblem": False,
    "error": "",
    "state": "empty",
  }


def empty_sand() -> dict[str, Any]:
  return {
    **empty_probe(),
    "used": None,
    "periodStart": "",
    "resetsAt": "",
    "planLabel": "",
    "cursorPlan": "",
    "billingBrand": "",
    "hasAvailableUsage": False,
    "includedLimitZero": False,
    "onDemandEligible": False,
    "dashboardUrl": "https://cursor.com/dashboard/spending",
    "categories": [],
  }


def empty_cursor() -> dict[str, Any]:
  return {
    **empty_probe(),
    "autoUsed": None,
    "apiUsed": None,
    "periodStart": "",
    "resetsAt": "",
    "displayMessage": "",
  }


def empty_supergrok() -> dict[str, Any]:
  return {
    **empty_probe(),
    "used": None,
    "periodStart": "",
    "resetsAt": "",
    "tierLabel": "",
  }


def empty_update() -> dict[str, Any]:
  return {
    "checkedAt": "",
    "attemptedAt": "",
    "error": "",
    "installed": "",
    "latest": "",
    "url": "",
    "available": False,
    "askedWith": "",
  }


def empty_record() -> dict[str, Any]:
  return {
    "schemaVersion": SCHEMA,
    "sand": empty_sand(),
    "cursor": empty_cursor(),
    "supergrok": empty_supergrok(),
    "update": empty_update(),
  }


def _copy_known(dst: dict[str, Any], src: dict[str, Any], keys: tuple[str, ...]) -> None:
  for key in keys:
    if key in src:
      dst[key] = src[key]


def migrate_v1(raw: dict[str, Any]) -> dict[str, Any]:
  rec = empty_record()
  usage = raw.get("usage") if isinstance(raw.get("usage"), dict) else {}
  sand = empty_sand()
  sand.update({
    "ok": bool(raw.get("ok")),
    "attemptedAt": str(raw.get("attemptedAt") or ""),
    "fetchedAt": str(raw.get("fetchedAt") or ""),
    "authProblem": bool(raw.get("authProblem")),
    "error": str(raw.get("error") or ""),
  })
  _copy_known(sand, usage, (
    "used", "periodStart", "resetsAt", "planLabel", "cursorPlan", "billingBrand",
    "hasAvailableUsage", "includedLimitZero", "onDemandEligible", "dashboardUrl",
  ))
  categories = raw.get("categories")
  sand["categories"] = categories if isinstance(categories, list) else []
  rec["sand"] = with_state(sand)

  cursor_body = raw.get("cursor") if isinstance(raw.get("cursor"), dict) else None
  cursor_error = str(raw.get("cursorError") or "")
  cursor = empty_cursor()
  if cursor_body is not None:
    _copy_known(cursor, cursor_body, ("autoUsed", "apiUsed", "periodStart", "resetsAt", "displayMessage"))
    cursor.update({
      "ok": not cursor_error,
      "attemptedAt": str(raw.get("attemptedAt") or ""),
      "fetchedAt": str(cursor_body.get("fetchedAt") or raw.get("fetchedAt") or ""),
      "authProblem": False,
      "error": cursor_error,
    })
  rec["cursor"] = with_state(cursor)
  return rec


def normalize_v2(raw: dict[str, Any]) -> dict[str, Any]:
  rec = empty_record()
  for name, blank in (
    ("sand", empty_sand),
    ("cursor", empty_cursor),
    ("supergrok", empty_supergrok),
    ("update", empty_update),
  ):
    section = raw.get(name)
    if isinstance(section, dict):
      merged = blank()
      merged.update(section)
      rec[name] = with_state(merged) if name != "update" else merged
  app = raw.get("app")
  if isinstance(app, dict):
    rec["app"] = {
      "running": bool(app.get("running")),
      "pid": app.get("pid") if isinstance(app.get("pid"), int) else None,
      "since": str(app.get("since") or ""),
    }
  rec["schemaVersion"] = SCHEMA
  return rec


def load_record(path: Path | None = None) -> dict[str, Any]:
  target = path or (state_dir() / "usage.json")
  raw = load_json(target)
  if not raw:
    return empty_record()
  if int(raw.get("schemaVersion") or 0) >= 2 and isinstance(raw.get("sand"), dict):
    return normalize_v2(raw)
  return migrate_v1(raw)


def publish(sections: dict[str, Any], path: Path | None = None) -> dict[str, Any]:
  target = path or (state_dir() / "usage.json")
  lock_path = target.parent / ".usage.lock"
  with open(lock_path, "w", encoding="utf-8") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    rec = load_record(target)
    rec["schemaVersion"] = SCHEMA
    for name, section in sections.items():
      if name not in SECTIONS:
        continue
      if section is None:
        rec.pop(name, None)
        continue
      data = dict(section)
      if name in ("sand", "cursor", "supergrok"):
        data = with_state(data)
      rec[name] = data
    write_json(target, rec)
    return rec


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
    write_json(path, {"schemaVersion": HISTORY_SCHEMA, "updatedAt": iso(now), "points": points})


# ---------------------------------------------------------------- section writers

def _keep_probe(previous: dict[str, Any], now: datetime, error: str, auth: bool) -> dict[str, Any]:
  out = dict(previous)
  out.update({
    "ok": False,
    "attemptedAt": iso(now),
    "authProblem": auth,
    "error": error,
  })
  return with_state(out)


def fetch_sand(token: str, previous: dict[str, Any], now: datetime) -> dict[str, Any]:
  if not token:
    return _keep_probe(previous, now, "No Cursor sign-in found. Open Cursor and sign in.", True)
  try:
    usage = parse_sand(rpc(SAND_METHOD, token, {}))
  except RpcError as error:
    return _keep_probe(previous, now, str(error), error.auth)
  out = dict(previous)
  out.update(usage)
  out.update({
    "ok": True,
    "attemptedAt": iso(now),
    "fetchedAt": iso(now),
    "authProblem": False,
    "error": "",
    "categories": fetch_categories(token, parse_iso(usage.get("periodStart")), now),
  })
  return with_state(out)


def fetch_cursor(token: str, previous: dict[str, Any], now: datetime) -> dict[str, Any]:
  if not token:
    return _keep_probe(previous, now, "No Cursor sign-in found. Open Cursor and sign in.", True)
  try:
    cursor = parse_cursor(rpc(CURSOR_METHOD, token, {}))
  except RpcError as error:
    return _keep_probe(previous, now, str(error), error.auth)
  out = dict(previous)
  out.update(cursor)
  out.update({
    "ok": True,
    "attemptedAt": iso(now),
    "fetchedAt": iso(now),
    "authProblem": False,
    "error": "",
  })
  return with_state(out)


def read_grok_login(home: Path | None = None) -> dict[str, str] | None:
  """Pick the live grok.com OIDC session. Skip API-key entries: those are
  console keys and do not carry the SuperGrok weekly pool."""
  root = home if home is not None else grok_home()
  try:
    data = json.loads((root / "auth.json").read_text(encoding="utf-8"))
  except Exception:
    return None
  if not isinstance(data, dict):
    return None
  now = utcnow()
  best: dict[str, Any] | None = None
  best_expiry: datetime | None = None
  for entry in data.values():
    if not isinstance(entry, dict):
      continue
    if str(entry.get("auth_mode") or "") not in ("oidc", "oauth", ""):
      continue
    key = str(entry.get("key") or "").strip()
    if key == "" or key.startswith("sk-") or key.startswith("xai-"):
      continue
    expires = parse_iso(entry.get("expires_at"))
    if best is None:
      best = entry
      best_expiry = expires
      continue
    if expires and (best_expiry is None or expires > best_expiry):
      best = entry
      best_expiry = expires
    elif expires is None and best_expiry is not None and best_expiry < now:
      best = entry
      best_expiry = expires
  if best is None:
    return None
  key = str(best.get("key") or "").strip()
  if not key:
    return None
  return {"key": key, "user_id": str(best.get("user_id") or "")}


def fetch_supergrok(login: dict[str, str] | None, previous: dict[str, Any], now: datetime) -> dict[str, Any]:
  if login is None or not login.get("key"):
    return _keep_probe(previous, now, "Run grok login", True)
  try:
    url = checked_url(SUPERGROK_BILLING, SUPERGROK_HOST)
    request = urllib.request.Request(
      url,
      method="GET",
      headers={
        "Authorization": "Bearer " + login["key"],
        "X-XAI-Token-Auth": SUPERGROK_TOKEN_AUTH,
        "x-userid": login.get("user_id") or "",
        "Accept": "application/json",
      },
    )
    with _OPENER.open(request, timeout=15) as response:
      raw = response.read() or b"{}"
    data = json.loads(raw.decode("utf-8", errors="replace"))
    if not isinstance(data, dict):
      raise RpcError("Grok billing returned an unexpected payload")
    reading = parse_supergrok(data)
    label = settings_tier_label(login) or jwt_tier_label(login["key"]) or str(reading.get("tierLabel") or "")
    if not label:
      label = str(previous.get("tierLabel") or "")
    reading["tierLabel"] = label
  except urllib.error.HTTPError as error:
    if error.code in (401, 403):
      return _keep_probe(previous, now, "Run grok login", True)
    return _keep_probe(previous, now, f"Grok billing returned HTTP {error.code}", False)
  except RpcError as error:
    return _keep_probe(previous, now, str(error), error.auth)
  except Exception:
    return _keep_probe(previous, now, "Couldn't reach cli-chat-proxy.grok.com", False)
  out = dict(previous)
  out.update(reading)
  out.update({
    "ok": True,
    "attemptedAt": iso(now),
    "fetchedAt": iso(now),
    "authProblem": False,
    "error": "",
  })
  return with_state(out)


def with_availability(section: dict[str, Any], installed: str) -> dict[str, Any]:
  out = dict(section) if section else empty_update()
  out["installed"] = installed
  latest = str(out.get("latest") or "")
  out["available"] = bool(installed and latest and version_newer(latest, installed))
  if not installed:
    out["available"] = False
  return out


def apply_update_response(status: int, payload: dict[str, Any] | None,
                          installed: str, previous: dict[str, Any], now: datetime) -> dict[str, Any]:
  out = dict(previous) if previous else empty_update()
  out["attemptedAt"] = iso(now)
  out["installed"] = installed
  out["askedWith"] = installed
  if status == 204:
    out["checkedAt"] = iso(now)
    out["error"] = ""
    out["available"] = False
    return out
  data = payload if isinstance(payload, dict) else {}
  latest = str(data.get("version") or data.get("productVersion") or "")
  raw_url = str(data.get("url") or "")
  stored_url = ""
  if raw_url:
    try:
      stored_url = checked_url(raw_url, DOWNLOAD_HOST)
    except RpcError:
      out["checkedAt"] = iso(now)
      out["error"] = ""
      if latest:
        out["latest"] = latest
      out["url"] = ""
      out["available"] = False
      return out
  out["checkedAt"] = iso(now)
  out["error"] = ""
  if latest:
    out["latest"] = latest
  if stored_url:
    out["url"] = stored_url
  out["available"] = bool(latest and installed and version_newer(latest, installed))
  return out


def failed_update(previous: dict[str, Any], installed: str, now: datetime, error: str) -> dict[str, Any]:
  out = with_availability(previous, installed)
  out["attemptedAt"] = iso(now)
  out["error"] = error
  return out


def probe_update(installed: str, previous: dict[str, Any], now: datetime, *, force: bool = False) -> dict[str, Any]:
  prev = dict(previous) if previous else empty_update()
  if not installed:
    return with_availability(prev, "")
  checked = parse_iso(prev.get("checkedAt"))
  asked = str(prev.get("askedWith") or "")
  fresh = (not force and checked and asked == installed
           and (now - checked).total_seconds() < UPDATE_DUE_SECONDS)
  if fresh:
    return with_availability(prev, installed)
  url = UPDATE_FEED.format(installed=urllib.parse.quote(installed, safe=""))
  try:
    checked_url(url, API_DOMAIN)
    request = urllib.request.Request(url, method="GET", headers={"Accept": "application/json"})
    with _OPENER.open(request, timeout=15) as response:
      status = int(getattr(response, "status", 200) or 200)
      raw = response.read() or b""
  except urllib.error.HTTPError as error:
    if error.code == 204:
      return apply_update_response(204, None, installed, prev, now)
    return failed_update(prev, installed, now, f"update feed returned HTTP {error.code}")
  except Exception:
    return failed_update(prev, installed, now, "Couldn't reach the update feed")
  if status == 204 or not raw.strip():
    return apply_update_response(204, None, installed, prev, now)
  try:
    payload = json.loads(raw.decode("utf-8", errors="replace"))
  except ValueError:
    return failed_update(prev, installed, now, "update feed returned invalid JSON")
  if not isinstance(payload, dict):
    return failed_update(prev, installed, now, "update feed returned an unexpected payload")
  return apply_update_response(status, payload, installed, prev, now)


def app_section(previous: dict[str, Any] | None, proc: Path, now: datetime) -> dict[str, Any] | None:
  pid = find_main_process(proc)
  running = pid is not None
  prev = previous if isinstance(previous, dict) else None
  if prev is not None and prev.get("running") is running and prev.get("pid") == pid:
    return None
  return {"running": running, "pid": pid, "since": iso(now)}


def launch_argv() -> list[str]:
  if shutil.which("uwsm"):
    return ["uwsm", "app", "--", APP_NAME]
  return [APP_NAME]


def launch_app() -> None:
  subprocess.Popen(
    launch_argv(),
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
  )


def section_fresh(section: dict[str, Any], now: datetime, due_seconds: int, force: bool) -> bool:
  if force:
    return False
  fetched = parse_iso(section.get("fetchedAt"))
  return bool(section.get("ok") and fetched and (now - fetched).total_seconds() < due_seconds)


# ---------------------------------------------------------------- verbs

def cmd_usage(force: bool, due_seconds: int,
              now: datetime | None = None, local_db: Path | None = None) -> dict[str, Any]:
  rec = load_record()
  stamp = now or utcnow()
  sand_prev = rec["sand"] if isinstance(rec.get("sand"), dict) else empty_sand()
  cursor_prev = rec["cursor"] if isinstance(rec.get("cursor"), dict) else empty_cursor()
  sg_prev = rec["supergrok"] if isinstance(rec.get("supergrok"), dict) else empty_supergrok()
  update_prev = rec["update"] if isinstance(rec.get("update"), dict) else empty_update()

  sand_ok = section_fresh(sand_prev, stamp, due_seconds, force)
  cursor_ok = section_fresh(cursor_prev, stamp, due_seconds, force)
  sg_ok = section_fresh(sg_prev, stamp, due_seconds, force)

  token = ""
  if not sand_ok or not cursor_ok:
    token = read_token()
  sand = sand_prev if sand_ok else fetch_sand(token, sand_prev, stamp)
  cursor = cursor_prev if cursor_ok else fetch_cursor(token, cursor_prev, stamp)
  supergrok = sg_prev if sg_ok else fetch_supergrok(read_grok_login(), sg_prev, stamp)

  installed = installed_version(local_db)
  update = probe_update(installed, update_prev, stamp, force=force)
  checked = parse_iso(update_prev.get("checkedAt"))
  asked = str(update_prev.get("askedWith") or "")
  cache_fresh = (not force and checked and asked == installed
                 and (stamp - checked).total_seconds() < UPDATE_DUE_SECONDS)
  if not cache_fresh:
    update = apply_repo_update(update, installed, fetch_checkupdates())

  published = publish({
    "sand": sand,
    "cursor": cursor,
    "supergrok": supergrok,
    "update": update,
  })
  samples: list[tuple[str, float, str, str]] = []
  if sand.get("ok") and sand.get("used") is not None:
    samples.append((SERIES_GROKBOT, float(sand["used"]), str(sand.get("periodStart") or ""), str(sand.get("resetsAt") or "")))
  if cursor.get("ok"):
    for series, key in ((SERIES_CURSOR_AUTO, "autoUsed"), (SERIES_CURSOR_API, "apiUsed")):
      if cursor.get(key) is not None:
        samples.append((series, float(cursor[key]), str(cursor.get("periodStart") or ""), str(cursor.get("resetsAt") or "")))
  if supergrok.get("ok") and supergrok.get("used") is not None:
    samples.append((SERIES_SUPERGROK, float(supergrok["used"]), str(supergrok.get("periodStart") or ""), str(supergrok.get("resetsAt") or "")))
  if samples:
    try:
      update_history(samples, stamp)
    except OSError as error:
      print(f"grokbot-usage: history write failed ({error})", file=sys.stderr)
  return published


def collect(force: bool, due_seconds: int) -> dict[str, Any]:
  return cmd_usage(force, due_seconds)


def cmd_tick(proc: Path = Path("/proc"), local_db: Path | None = None,
             now: datetime | None = None) -> dict[str, Any]:
  rec = load_record()
  stamp = now or utcnow()
  installed = installed_version(local_db)
  prev_update = rec["update"] if isinstance(rec.get("update"), dict) else empty_update()
  asked = str(prev_update.get("askedWith") or "")
  if installed and installed != asked:
    next_update = apply_repo_update(
      probe_update(installed, prev_update, stamp, force=True),
      installed,
      fetch_checkupdates(),
    )
  else:
    next_update = with_availability(prev_update, installed)
  sections: dict[str, Any] = {}
  app = app_section(rec.get("app") if isinstance(rec.get("app"), dict) else None, proc, stamp)
  if app is not None:
    sections["app"] = app
  changed = (
    next_update.get("installed") != prev_update.get("installed")
    or next_update.get("available") != prev_update.get("available")
    or next_update.get("askedWith") != prev_update.get("askedWith")
    or next_update.get("latest") != prev_update.get("latest")
    or next_update.get("url") != prev_update.get("url")
    or next_update.get("error") != prev_update.get("error")
    or next_update.get("checkedAt") != prev_update.get("checkedAt")
    or next_update.get("attemptedAt") != prev_update.get("attemptedAt")
  )
  if changed:
    sections["update"] = next_update
  if sections:
    return publish(sections)
  return rec


def cmd_launch() -> int:
  launch_app()
  return 0


def cmd_print() -> int:
  record = load_record()
  print(json.dumps(record, indent=2, sort_keys=True))
  return 0


def main() -> int:
  parser = argparse.ArgumentParser(description="Collect Grok Bot weekly usage")
  sub = parser.add_subparsers(dest="cmd", required=True)
  usage_p = sub.add_parser("usage", help="probe sand, Cursor, SuperGrok, and the update feed")
  usage_p.add_argument("--force", action="store_true", help="ignore the reuse window")
  usage_p.add_argument("--due", type=int, default=DUE_SECONDS_DEFAULT,
                       help="reuse a live section if younger than this many seconds")
  sub.add_parser("tick", help="refresh app liveness and recompute update.available")
  sub.add_parser("launch", help="start Grok Bot (uwsm app -- grok-bot when uwsm is on PATH)")
  sub.add_parser("print", help="print usage.json (never includes a token)")
  args = parser.parse_args()
  if args.cmd == "usage":
    cmd_usage(args.force, max(0, args.due))
    return 0
  if args.cmd == "tick":
    cmd_tick()
    return 0
  if args.cmd == "launch":
    return cmd_launch()
  if args.cmd == "print":
    return cmd_print()
  return 2


if __name__ == "__main__":
  raise SystemExit(main())
