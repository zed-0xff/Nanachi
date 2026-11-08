#!/bin/sh
if [ -n "$PROJECT_NAME" -a -d "$PROJECT_NAME" ]; then
	cd "$PROJECT_NAME"
fi

#if [ -d .opencode ]; then
#	mkdir -p ~/.local/share
#	ln -s $(pwd)/.opencode ~/.local/share/opencode
#fi

exec "$@"
