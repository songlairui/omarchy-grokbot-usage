# Changelog

## 1.1.0

- The bar can start Grok Bot. The popup shows **Start Grok Bot** when the main process is down, and the menu shows **Open Grok Bot** when it is already running.
- A down process dims the face and draws a slash. A missing Cursor sign-in draws an outline face. A failed refresh keeps the last reading and stays dim. Those three states are separate.
- The popup charts SuperGrok weekly usage and names the plan, such as SuperGrok Heavy. Right-click toggles **Show Cursor** and **Show SuperGrok**. Both default to on.
- A newer Grok Bot build puts a dot on the lower left of the face. The popup has **Update Grok Bot**. If `checkupdates` lists a newer `grok-bot` package, that runs `omarchy-update`. Otherwise `omarchy agent prompt` asks the agent from `omarchy default agent` to install the upstream build. That build may be an AppImage when the Omarchy package is behind.
- `usage.json` is now schemaVersion 2. The next collect migrates an older file in place.

## 1.0.1

- The collector sends the Cursor token only to `https://cursor.sh` and its subdomains, and it refuses redirects.

## 1.0.0

- First release. Grok Bot weekly usage on the Omarchy bar, with a remaining meter and popup charts.
