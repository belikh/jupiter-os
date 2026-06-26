#!/bin/sh

# This script runs automatically on the first boot of the MX4300 OpenWrt firmware.
# It is used to statically configure UCI settings (like Headscale mesh, Wi-Fi, etc)
# before the router even comes online.

# Set the base hostname (you can parameterize this later if needed)
uci set system.@system[0].hostname='jupiter-ap'

# Example of configuring the wireless radios for your mesh network
# uci set wireless.radio0.disabled='0'
# uci set wireless.radio1.disabled='0'
# ...

# Commit changes
uci commit system
uci commit wireless

exit 0
