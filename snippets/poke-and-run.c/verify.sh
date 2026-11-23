#!/bin/sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HERE="$HERE" exec sh "$HERE/../common/verify.sh" "$@"
