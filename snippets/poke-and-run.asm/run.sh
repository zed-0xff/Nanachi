#!/bin/sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HERE="$HERE" BLOB_SIZE=348 LABEL=asm exec sh "$HERE/../common/run.sh" "$@"
