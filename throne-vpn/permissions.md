# TUN and DNS permissions

These are manual administrator setup steps, separate from the plugin. The plugin never invokes sudo/pkexec, installs rules, changes capabilities or stores a password. Run the GUI as the ordinary desktop user.

## Recommended: grant the core privileges through Throne

In the running Throne window select a profile, tick **Tun Mode**, accept the core privilege request and authenticate. Tick Tun Mode again if asked, then connect.

Upstream's Linux method changes only `ThroneCore` to root ownership and adds the SUID bit. It requires `pkexec` and a working Polkit authentication agent in the desktop session. The GUI does not need root. After an update replaces the core, repeat the grant if requested. Turning on **Disable Privilege request** does not grant missing rights.

The portable installation in the README uses:

```text
~/.local/opt/throne-1.4.0-beta.4/Throne/ThroneCore
```

Packages may instead install under `/opt/Throne` or `/usr/lib/throne`. Determine the actual executable used by your running installation before changing any rights.

Reference: [upstream TUN privileges](https://throneproj.github.io/guides/tun_mode/).

## Optional capability alternative

For administrators deliberately choosing file capabilities instead of the normal SUID method, upstream checks these five capabilities:

```sh
sudo setcap cap_net_admin,cap_net_raw,cap_net_bind_service,cap_sys_ptrace,cap_dac_read_search+ep /actual/path/to/ThroneCore
getcap /actual/path/to/ThroneCore
```

Replace the path with the actual core file. This is an alternative, not an additional step on an already-working SUID core. Capability-only operation does not meet the Linux kill switch's root requirement in the pinned release. Use the normal upstream method when that feature is needed. Do not grant capabilities to the GUI, Python or thronectl.

## Optional passwordless systemd-resolved actions

Use this section only when repeated prompts explicitly concern DNS configuration through systemd-resolved. TUN privileges and DNS authorization are different. Check the prompt's action IDs first; this rule does not repair a missing core privilege or a broken API key.

This rule allows **only four DNS actions**, for members of a dedicated group, in an **active local session**. It authorizes every program of those users for these DNS operations, not only Throne. It does not grant general sudo/pkexec rights. No personal account name is hard-coded.

Run as your normal user in Bash, authenticating for the administrative commands:

```sh
sudo groupadd -f throne-vpn-dns
sudo usermod -aG throne-vpn-dns "$(id -un)"
sudo tee /etc/polkit-1/rules.d/50-throne-vpn-dns.rules >/dev/null <<'RULE'
polkit.addRule(function(action, subject) {
    var allowed = [
        "org.freedesktop.resolve1.set-dns-servers",
        "org.freedesktop.resolve1.set-domains",
        "org.freedesktop.resolve1.set-default-route",
        "org.freedesktop.resolve1.revert"
    ];
    if (subject.local && subject.active &&
        subject.isInGroup("throne-vpn-dns") &&
        allowed.indexOf(action.id) !== -1) {
        return polkit.Result.YES;
    }
});
RULE
sudo chmod 0644 /etc/polkit-1/rules.d/50-throne-vpn-dns.rules
```

Log out of the graphical session and log back in so its processes inherit the new group membership. Polkit normally reloads rule files automatically. Check membership with `id -nG`, then retry. Do not disable authentication globally if another action still prompts.

To undo the optional permission:

```sh
sudo rm /etc/polkit-1/rules.d/50-throne-vpn-dns.rules
sudo gpasswd -d "$(id -un)" throne-vpn-dns
```

Log out/in again. The group can remain empty; do not delete a group used by other accounts.

References: [Polkit rules and subjects](https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html), [systemd-resolved D-Bus API](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.resolve1.html).
