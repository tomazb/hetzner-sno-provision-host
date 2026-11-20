#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Preserve the old wrapper's ignored-arguments behavior and Debian 12 default.
exec "${SCRIPT_DIR}/test-debian-container.sh" 12
