#!/bin/sh -xe

# for externally mounted session storage
mkdir -p .local/share/opencode

# validate opencode config at container build time
jq . < .config/opencode/opencode.json > /dev/null

for f in $(find .config/opencode -name package.json); do
	npm install --prefix $(dirname $f)
done

# referenced by opencode.json
npm install @opencode/ai @aerovato/operator-helper

~/node_modules/.bin/operator-helper install opencode
