#!/bin/bash
# entrypoint.sh — IT-Stack taiga container entrypoint
set -euo pipefail

echo "Starting IT-Stack TAIGA (Module 15)..."

# Source any environment overrides
if [ -f /opt/it-stack/taiga/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/taiga/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
