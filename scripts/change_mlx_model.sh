#!/usr/bin/env bash
# Compatibility wrapper — use scripts/change_model.sh instead.
exec "$(dirname "${BASH_SOURCE[0]}")/change_model.sh" "$@"
