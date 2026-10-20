#!/bin/bash
cd "$(dirname "$0")"
bash "./collect-device-health-mac.sh"
printf '\nPress Enter to close...'
read -r _
