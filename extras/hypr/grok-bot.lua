-- Optional: keep Grok Bot running in the background on Omarchy (Hyprland Lua config).
-- NOT loaded by anything in this repo. To use it, copy the lines below into
-- ~/.config/hypr/autostart.lua (or `require` this file from hyprland.lua).
--
-- Grok Bot has no tray icon and quits when its last window closes, so
-- "background" here means: start at login straight into the scratchpad
-- (special:scratchpad, toggled with SUPER + S in Omarchy) and hide it there
-- instead of closing it.

-- Start at login under uwsm (systemd scope app-grok-bot-*.scope).
o.launch_on_start("grok-bot")

-- Every Grok Bot window opens silently on the scratchpad; SUPER + S shows it.
o.window("^(grok-bot)$", { workspace = "special:scratchpad silent" })

-- Optional dedicated toggle (SUPER + G / SUPER + ALT + G are taken by grouping):
-- o.bind("SUPER + CTRL + G", "Toggle Grok Bot", hl.dsp.workspace.toggle_special("scratchpad"))
