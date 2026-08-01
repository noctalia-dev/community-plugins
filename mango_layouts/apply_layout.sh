#!/bin/bash
LAYOUT=$1
GLOBAL=$2
CONF_DIR="$HOME/.config/mango/conf.d"
CONF_FILE="$CONF_DIR/workspaces.conf"

mmsg dispatch setlayout,$LAYOUT

TMP_FILE=$(mktemp "$CONF_DIR/workspaces_XXXXXX.tmp")
cp "$CONF_FILE" "$TMP_FILE"

if [ "$GLOBAL" = "true" ]; then
    sed -i "s/layout_name:[a-zA-Z_]*/layout_name:$LAYOUT/g" "$TMP_FILE"
else
    ACTIVE_TAG=$(mmsg get all-tags | jq -r '.all_tags[0].tags[] | select(.is_active==true) | .index')
    if [ -n "$ACTIVE_TAG" ]; then
        sed -i "s/tagrule=id:$ACTIVE_TAG,no_hide:1,layout_name:[a-zA-Z_]*/tagrule=id:$ACTIVE_TAG,no_hide:1,layout_name:$LAYOUT/g" "$TMP_FILE"
    fi
fi

mv "$TMP_FILE" "$CONF_FILE"
