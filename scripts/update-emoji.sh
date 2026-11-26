#!/bin/sh
# Regenerates Sources/PufferCore/EmojiData.swift from the latest Unicode
# emoji list and CLDR English annotations. Needs the network; the app does not.
set -eu
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/emoji-test.txt" https://unicode.org/Public/emoji/latest/emoji-test.txt
curl -fsSL -o "$work/annotations.xml" https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/en.xml
curl -fsSL -o "$work/derived.xml" https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/en.xml

swift scripts/generate-emoji.swift "$work/emoji-test.txt" "$work/annotations.xml" "$work/derived.xml" > "$work/EmojiData.swift"
mv "$work/EmojiData.swift" Sources/PufferCore/EmojiData.swift
echo "Wrote Sources/PufferCore/EmojiData.swift ($(grep -c "$(printf '\t')" Sources/PufferCore/EmojiData.swift) emoji)"
