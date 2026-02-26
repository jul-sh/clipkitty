#!/usr/bin/env bash
set -euo pipefail

VERSION="$1"
EDDSA_SIGNATURE="$2"
FILE_LENGTH="$3"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>ClipKitty Updates</title>
    <link>https://jul-sh.github.io/clipkitty/appcast.xml</link>
    <language>en</language>
    <item>
      <title>ClipKitty ${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <enclosure url="https://github.com/jul-sh/clipkitty/releases/download/v${VERSION}/ClipKitty.dmg"
                 type="application/octet-stream"
                 sparkle:edSignature="${EDDSA_SIGNATURE}"
                 length="${FILE_LENGTH}" />
    </item>
  </channel>
</rss>
EOF
