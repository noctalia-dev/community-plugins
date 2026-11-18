# Changelog

## 1.3.0 (2026-11-16)

Fixes from review, and laptops other than the one it was built on:

- The panel no longer hides Display, Lighting and Sensors on laptops without a UPower charge limit or panel overdrive. Sections were collected in a list with gaps, which `ipairs` stopped at.
- AMD models: the quiet mode (`low-power` in the kernel, LowPower in asusd) shows and works as Silent. Ryzen CPU temperature comes from `k10temp`. The GPU status line finds an AMD discrete GPU too and names the vendor. asusd's Custom profile is shown by name.
- Keyboard lighting and Slash keep working after the keyboard re-enumerates (resume, detachable keyboards). asusd's objects carry the USB device number, so the service now re-reads when objects are added or removed.
- When asusd leaves the bus the panel says so at once, and a read that failed or timed out is retried on the next tick instead of leaving "asusd isn't running" up until the next change.
- Pressing the mode or Aura key twice quickly moves two steps, not one.
- A refused write (for example, polkit declining the charge limit) puts the toggle back where the hardware is.
- If the current lighting effect isn't one the panel offers (a rainbow on a single-colour keyboard, or an effect set with asusctl), it is shown instead of a wrong "Static".
- The charge limit and battery readings use the laptop's own battery, never a mouse's or controller's.
- A mode change is one asusd write instead of two (asusd's per-source setter already applies it). Each write makes the firmware notify the NVIDIA driver, which wakes the GPU.
- Graphics switching through asusd is offered only when asusd queues switches until shutdown (`QueuedGpuValue`); an older asusd would cut the GPU off live.
- **Changed:** Match theme colour is now off until you turn it on, so nothing is written to the keyboard at startup. If you used it, turn it back on in the panel. Changing other settings no longer repaints the keyboard.

## 1.2.0 (2026-11-16)

- Aura key support: `next-aura` and `previous-aura` step through the keyboard's lighting effects, with an on-screen confirmation like the one for performance modes. Also `previous-profile`.
- New `rgb_keyboard` setting for single-colour keyboards (many ROG models are white-only, which asusd can't tell apart from RGB): hides the colour and rainbow options, keeps the Aura key to Static, Breathe and Pulse, and stops the theme-colour updates.
- Settings changes apply in place instead of restarting the service.

## 1.1.0 (2026-11-15)

- Graphics mode switching goes through asusd, upstream asusctl's replacement for the deprecated supergfxd. asusd queues the switch and asusctl's `asus-shutdown` service applies it during shutdown, so it takes effect at the next start. Until then the panel shows the pending mode with Restart and Cancel. If supergfxd is running, it is still used.
- When a laptop offers only one graphics mode, the panel shows it as text instead of a one-option switch.

## 1.0.0 (2026-11-15)

- First release: performance modes (with per-power-source defaults), battery charge limit through UPower, graphics mode, panel overdrive, keyboard lighting and Slash, fan speeds and CPU temperature, a bar widget, a Control Center tile and IPC.
