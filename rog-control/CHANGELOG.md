# Changelog

## 1.2.0 (2026-11-16)

- Aura key support: `next-aura` and `previous-aura` step through the keyboard's lighting effects, with an on-screen confirmation like the one for performance modes. Also `previous-profile`.
- New `rgb_keyboard` setting for single-colour keyboards (many ROG models are white-only, which asusd can't tell apart from RGB): hides the colour and rainbow options, keeps the Aura key to Static, Breathe and Pulse, and stops the theme-colour updates.
- Settings changes apply in place instead of restarting the service.

## 1.1.0 (2026-11-15)

- Graphics mode switching goes through asusd, upstream asusctl's replacement for the deprecated supergfxd. asusd queues the switch and asusctl's `asus-shutdown` service applies it during shutdown, so it takes effect at the next start. Until then the panel shows the pending mode with Restart and Cancel. If supergfxd is running, it is still used.
- When a laptop offers only one graphics mode, the panel shows it as text instead of a one-option switch.

## 1.0.0 (2026-11-15)

- First release: performance modes (with per-power-source defaults), battery charge limit through UPower, graphics mode, panel overdrive, keyboard lighting and Slash, fan speeds and CPU temperature, a bar widget, a Control Center tile and IPC.
