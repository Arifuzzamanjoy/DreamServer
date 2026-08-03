#!/bin/sh
set -eu

mode="${ODS_MODE:-local}"
switchboard="${ODS_MODEL_SWITCHBOARD:-observe}"
mode_config="${1:-/app/config.yaml}"
switchboard_config="${2:-/app/switchboard.yaml}"

# Some modes own their routing outright and the switchboard must not override
# them:
#
#   cloud  cloud routing is authoritative.
#   mesh   peer routing is authoritative. The switchboard config points every
#          alias at this node's own model-router, so honouring it in mesh mode
#          would pull peer traffic back into local inference and bypass the
#          peer gateway -- exactly what ODS-RUNTIME-MESH-LLM-LOCAL-ROUTE and
#          ODS-RUNTIME-MESH-GATEWAY-BYPASS exist to catch.
#
# The mode config itself is chosen by the compose mount
# (./config/litellm/${ODS_MODE}.yaml), so mesh mode resolves to mesh.yaml.
case "$mode" in
    cloud|mesh) routing_is_authoritative=1 ;;
    *)          routing_is_authoritative=0 ;;
esac

if [ "$routing_is_authoritative" -eq 0 ] && [ "$switchboard" = "enabled" ]; then
    printf '%s\n' "$switchboard_config"
else
    printf '%s\n' "$mode_config"
fi
