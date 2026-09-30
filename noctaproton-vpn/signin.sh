#!/usr/bin/env bash
# Interactive Proton VPN Sign-in Launcher for Noctalia Shell

clear
echo "=========================================="
echo "           Proton VPN Sign In             "
echo "=========================================="
echo ""

USER="$1"
if [ -z "$USER" ]; then
  read -rp "Enter Proton Username or Email: " USER
fi

USER="$(echo "$USER" | xargs)"

if [ -z "$USER" ]; then
  echo ""
  echo "Error: Username cannot be blank."
  echo ""
  read -rp "Press Enter to close..."
  exit 1
fi

echo ""
echo "Connecting to Proton authentication service for '$USER'..."
echo ""
protonvpn signin "$USER"
code=$?

echo ""
if [ $code -eq 0 ]; then
  echo "=========================================="
  echo "✓ Successfully signed in to Proton VPN!"
  echo "=========================================="
else
  echo "=========================================="
  echo "✗ Sign in exited with code $code"
  echo "=========================================="
fi

echo ""
read -rp "Press Enter to finish and close this window..."
exit $code
