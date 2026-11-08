#!/bin/bash -e

set -a
[ -f .env ] && . .env
set +a

openshell sandbox delete opencode

docker build -t opencode-sandbox .

openshell sandbox create \
	--name opencode \
	--from opencode-sandbox:latest \
	--policy policy.yaml \
        --forward 0.0.0.0:4096 \
	--driver-config-json "$(envsubst < driver-config.json | jq -c .)" \
        --env PROJECT_NAME=Nanachi \
        --env-from OPENCODE_SERVER_PASSWORD \
        --env OPENCODE_MAX_IMAGES=1 \
	--detach \
	-- ./ep.sh opencode serve --print-logs
