#!/bin/sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HERE="$HERE" BLOB_SIZE=300 LABEL=c exec sh "$HERE/../common/run.sh" "$@"
