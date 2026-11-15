#!/usr/bin/env bash
# Interactive Proton VPN sign-in, opened in a terminal from the panel.
# Credentials and 2FA are typed straight into the official CLI.
read -r -p "Proton username or email: " user
if [ -n "$user" ]; then
	protonvpn signin "$user"
fi
echo
read -r -p "Press Enter to close… " _
