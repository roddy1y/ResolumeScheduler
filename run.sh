#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
./build-app.sh
open "$HOME/Desktop/ResolumeScheduler.app"
