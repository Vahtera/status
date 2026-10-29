#!/bin/bash

RESET=$'\033[0m'
black=$'\033[30m'
red=$'\033[31m'
green=$'\033[32m'
yellow=$'\033[33m'
blue=$'\033[34m'
magenta=$'\033[35m'
cyan=$'\033[36m'
white=$'\033[37m'
light_black=$'\033[90m'
light_red=$'\033[91m'
light_green=$'\033[92m'
light_yellow=$'\033[93m'
light_blue=$'\033[94m'
light_magenta=$'\033[95m'
light_cyan=$'\033[96m'
light_white=$'\033[97m'

COLOR_BORDER=$light_black
COLOR_TITLE=$cyan
COLOR_KEY=$blue
COLOR_OUTPUT=$white
BORDER_WIDTH=40

if [[ -n ${NO_COLOR:-} || ( ! -t 1 && -z ${FORCE_COLOR:-} ) ]]; then
    RESET='' COLOR_BORDER='' COLOR_TITLE='' COLOR_KEY=''
    COLOR_OUTPUT=''
fi

section() {
    local title=$1 key value
    shift
    local -a keys=() values=()

    while (($#)); do
        key=$1 value=$2
        keys+=("$key")
        values+=("$value")
        shift 2
    done

    local padding
    printf -v padding '%*s' "$((BORDER_WIDTH - ${#title} - 6))" ''
    printf '%b╭─[%b %s %b]%b%s%b\n' \
        "$COLOR_BORDER" "$COLOR_TITLE" "$title" "$COLOR_BORDER" "$COLOR_BORDER" \
        "${padding// /─}" "$RESET"

    for i in "${!keys[@]}"; do
        printf '%b│%b ' "$COLOR_BORDER" "$RESET"
        printf '%b%-14s%b %b%s%b' \
            "$COLOR_KEY" "${keys[i]}:" "$RESET" \
            "$COLOR_OUTPUT" "${values[i]}" "$RESET"
        printf '\n'
    done

    printf -v padding '%*s' "$((BORDER_WIDTH - 1))" ''
    printf '%b╰%s%b\n' "$COLOR_BORDER" "${padding// /─}" "$RESET"
}

bytes() {
    numfmt --to=iec-i --format='%.2f' "$1" | sed -E 's/([0-9.]+)([A-Za-z]*)$/\1 \2B/'
}

percent() {
    awk -v used="$1" -v total="$2" 'BEGIN { if (total) printf "%.0f", used * 100 / total; else print 0 }'
}

host=$(hostname)
bios=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || tr -d '\000' < /proc/device-tree/model 2>/dev/null || printf 'Unavailable')
cpu=$(awk -F': *' '/^(model name|Hardware|Model)[[:space:]]*:/ { print $2; exit }' /proc/cpuinfo)
[[ -n $cpu ]] || cpu=$(uname -m)
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '?')
frequency=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
if [[ $frequency =~ ^[0-9]+$ ]]; then
    frequency=$(awk -v khz="$frequency" 'BEGIN { printf "%.2f GHz", khz / 1000000 }')
else
    frequency='frequency unavailable'
fi
cpu="$cpu ($cores) @ $frequency"

read -r memory_total memory_used < <(free -b | awk '/^Mem:/ { print $2, $3 }')
read -r swap_total swap_used < <(free -b | awk '/^Swap:/ { print $2, $3 }')
memory="${memory_total:+$(bytes "$memory_used") / $(bytes "$memory_total") ($(percent "$memory_used" "$memory_total")%)}"
swap="${swap_total:+$(bytes "$swap_used") / $(bytes "$swap_total") ($(percent "$swap_used" "$swap_total")%)}"
[[ -n $memory ]] || memory='Unavailable'
[[ -n $swap ]] || swap='Unavailable'

os=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)
[[ -n $os ]] || os=$(uname -o)
kernel=$(uname -sr)
uptime=$(uptime -p 2>/dev/null | sed -e 's/^up //' -e 's/minutes/mins/' -e 's/minute/min/')
[[ -n $uptime ]] || uptime='Unavailable'
local_ip=$(ip -o -4 addr show scope global 2>/dev/null | awk '{ print $4 }' | paste -sd ' ')
[[ -n $local_ip ]] || local_ip='Unavailable'
tailscale_ip=''
if command -v tailscale >/dev/null 2>&1; then
    tailscale_ip=$(tailscale ip -4 2>/dev/null | paste -sd ' ')
fi
dns=$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ { printf "%s%s", separator, $2; separator = " " }' /etc/resolv.conf)
[[ -n $dns ]] || dns='Unavailable'

public_json=$(curl -4fsS --max-time 3 https://ipinfo.io/json 2>/dev/null || true)
public_ip=$(printf '%s\n' "$public_json" | sed -n 's/^[[:space:]]*"ip":[[:space:]]*"\([^"]*\)".*/\1/p')
city=$(printf '%s\n' "$public_json" | sed -n 's/^[[:space:]]*"city":[[:space:]]*"\([^"]*\)".*/\1/p')
country=$(printf '%s\n' "$public_json" | sed -n 's/^[[:space:]]*"country":[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -n $public_ip ]]; then
    public_ip="$public_ip${city:+ ($city${country:+, $country})}"
else
    public_ip='Unavailable'
fi

hardware=(
    Host "$host"
    BIOS "$bios"
    CPU "$cpu"
    Memory "$memory"
    Swap "$swap"
)

while read -r filesystem type total used _; do
    [[ -n $filesystem && $filesystem != Filesystem ]] || continue
    [[ $filesystem == /dev/* && $type != efivarfs ]] || continue
    disk="$(bytes "$used") / $(bytes "$total") ($(percent "$used" "$total")%) - $type"
    hardware+=(Disk "$disk")
done < <(df -PT -B1 -x tmpfs -x devtmpfs -x squashfs 2>/dev/null)
section 'Hardware' "${hardware[@]}"

section 'System' \
    OS "$os" \
    Kernel "$kernel" \
    Uptime "$uptime"

network=('Local IP' "$local_ip")
[[ -z $tailscale_ip ]] || network+=('Tailscale IP' "$tailscale_ip")
network+=(DNS "$dns" 'Public IP' "$public_ip")
section 'Network' "${network[@]}"

service_status() {
    local service=$1 state
    if command -v systemctl >/dev/null 2>&1; then
        state=$(systemctl is-active "$service" 2>/dev/null || true)
        [[ -n $state ]] || state='unknown'
    else
        state='systemd unavailable'
    fi

    case $state in
        active) state='active (running)' ;;
    esac
    printf '%s' "$state"
}

services=()
for service in ssh dnsmasq tailscaled; do
    state=$(service_status "$service")
    services+=("$service" "$state")
done
section 'Services' "${services[@]}"
