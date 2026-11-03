#!/bin/bash
# Script to get the battery percentage of a Bluetooth device using
# bluetoothctl and output it in JSON format for use with Noctalia
# plugin tordex/stdout.
#
# Arguments:
#   $1: The MAC address of the Bluetooth device.
#
# To get the MAC address of a Bluetooth device, run `bluetoothctl devices` and look for
# the device you want to monitor.

trim() {
	local var="$*"
	# remove leading whitespace characters
	var="${var#"${var%%[![:space:]]*}"}"
	# remove trailing whitespace characters
	var="${var%"${var##*[![:space:]]}"}"
	echo -n "$var"
}

bt_output=$(bluetoothctl info $1)

battery=$(echo "$bt_output" | grep "Battery Percentage" | tr -d '()' | awk '{print $4}')%
name=$(echo "$bt_output" | grep "Name:" |  awk -F':' '{print $2}')
paired=$(echo "$bt_output" | grep "Paired:" |  awk -F':' '{print $2}')
bonded=$(echo "$bt_output" | grep "Bonded:" |  awk -F':' '{print $2}')
trusted=$(echo "$bt_output" | grep "Trusted:" |  awk -F':' '{print $2}')
connected=$(echo "$bt_output" | grep "Connected:" |  awk -F':' '{print $2}')
icon=$(echo "$bt_output" | grep "Icon:" |  awk -F':' '{print $2}')

connected=$(trim "$connected")
icon=$(trim "$icon")

if [ -z "$name" ] || [ "$connected" != "yes" ]; then
	echo "{\"visible\": false}"
else
	color="null"
	if (( ${battery%?} < 20 )); then
		color="\"error\""
	fi

	case "$icon" in
    	"input-mouse")
        	icon="mouse"
        	;;
    	"input-gaming")
        	icon="bluetooth-device-gamepad"
        	;;
		"input-keyboard")
			icon="keyboard"
			;;
		"audio-headset")
			icon="headset"
			;;
		"audio-headphones")
			icon="headphones"
			;;
		"audio-card")
			icon="music"
			;;
		"audio-speakers")
			icon="device-speaker"
			;;
		"phone")
			icon="device-mobile"
			;;
		"input-tablet")
			icon="device-tablet"
			;;
    	*)
        	icon="bluetooth"
        	;;
	esac

	jq -n \
		--arg name "$(trim "$name")" \
		--arg paired "$(trim "$paired")" \
		--arg battery "$(trim "$battery")" \
		--arg bonded "$(trim "$bonded")" \
		--arg trusted "$(trim "$trusted")" \
		--arg icon "$icon" \
		--argjson color "$color" \
		'{
			visible: true,
			glyph: $icon,
			text: $battery,
			textColor: $color,
			glyphColor: $color,
			tips: [
				[ "Name:", $name ],
				[ "Paired:", $paired ],
				[ "Bonded:", $bonded ],
				[ "Trusted:", $trusted ]
			]
		}'
fi

