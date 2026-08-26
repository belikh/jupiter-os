#!/usr/bin/env bash
# USB port power cycler - disables each port for 2s to identify which powers a device
# Run as root on the target machine

set -euo pipefail

ROOT_HUB="/sys/bus/usb/devices/1-0:1.0"
DOWNSTREAM_HUBS=("1-1:1.0" "1-4:1.0" "1-7:1.0")

echo "=== USB Port Power Cycler ==="
echo "Will disable each port for 2 seconds, then re-enable"
echo "Watch your neon light to identify the port"
echo ""

# Function to cycle a port
cycle_port() {
    local port_path="$1"
    local port_name=$(basename "$port_path")
    
    local disable_file="$port_path/disable"
    local state_file="$port_path/state"
    
    if [[ ! -f "$disable_file" ]]; then
        echo "  [$port_name] No disable file, skipping"
        return
    fi
    
    local state_before=$(cat "$state_file" 2>/dev/null || echo "unknown")
    echo "  [$port_name] State: $state_before -> DISABLING..."
    
    echo 1 > "$disable_file"
    sleep 2
    
    local state_during=$(cat "$state_file" 2>/dev/null || echo "unknown")
    echo "  [$port_name] State during disable: $state_during -> RE-ENABLING..."
    
    echo 0 > "$disable_file"
    sleep 1
    
    local state_after=$(cat "$state_file" 2>/dev/null || echo "unknown")
    echo "  [$port_name] State after: $state_after"
    echo ""
}

# Cycle root hub ports
echo "=== Root Hub (1-0:1.0) ==="
for port in "$ROOT_HUB"/usb1-port*; do
    cycle_port "$port"
done

# Cycle downstream hub ports
for hub in "${DOWNSTREAM_HUBS[@]}"; do
    hub_path="/sys/bus/usb/devices/$hub"
    if [[ -d "$hub_path" ]]; then
        echo "=== Downstream Hub ($hub) ==="
        for port in "$hub_path"/*-port*; do
            [[ -d "$port" ]] && cycle_port "$port"
        done
    fi
done

echo "=== Done ==="