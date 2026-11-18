#!/usr/bin/env bash
PACKAGES=$(xbps-install -Mnu | jq -Rr '. | match("(.*?)-([^-]*?) ").captures | map(.string) | join("|")')
PREFIX=""
echo '{"updates":['
for PACKAGE in $PACKAGES
do
    echo $PREFIX
    PREFIX=","
    PACKAGE_NAME=$(echo $PACKAGE | cut -d '|' -f1)
    PACKAGE_NEW_VERSION=$(echo $PACKAGE | cut -d '|' -f2)
    PACKAGE_CURRENT_VERSION=$(xbps-query "$PACKAGE_NAME" | grep 'pkgver:' | jq -Rr '.| match("pkgver: (.*?)-([^-]*?)$").captures[1].string')
    echo {\"id\": \"$PACKAGE_NAME\"", \"name\": \"$PACKAGE_NAME\", \"from_version\": \"$PACKAGE_CURRENT_VERSION\", \"to_version\": \"$PACKAGE_NEW_VERSION\", \"description\": \"\", \"icon\": \"\", \"glyph\": \"brand-node\"}"
done
echo "]}"