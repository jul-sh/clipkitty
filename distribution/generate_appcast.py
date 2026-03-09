#!/usr/bin/env python3

import argparse
import json
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from xml.dom import minidom
from xml.etree.ElementTree import Element, SubElement, register_namespace, tostring


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NAMESPACE = "http://purl.org/dc/elements/1.1/"


def format_pub_date(value: str | None) -> str:
    if not value:
        return format_datetime(datetime.now(timezone.utc))

    normalized = value.replace("Z", "+00:00")
    return format_datetime(datetime.fromisoformat(normalized))


def add_item(channel: Element, release_channel: str, release: dict[str, object]) -> None:
    item = SubElement(channel, "item")
    version = str(release["version"])
    title = f"ClipKitty {version}"
    if release_channel == "beta":
        title = f"{title} Beta"

    SubElement(item, "title").text = title
    SubElement(item, f"{{{SPARKLE_NAMESPACE}}}version").text = version
    SubElement(item, f"{{{SPARKLE_NAMESPACE}}}shortVersionString").text = version
    SubElement(item, f"{{{SPARKLE_NAMESPACE}}}minimumSystemVersion").text = "14.0"

    minimum_autoupdate_version = release.get("minimum_autoupdate_version")
    if minimum_autoupdate_version:
        SubElement(item, f"{{{SPARKLE_NAMESPACE}}}minimumAutoupdateVersion").text = str(minimum_autoupdate_version)

    if release_channel == "beta":
        SubElement(item, f"{{{SPARKLE_NAMESPACE}}}channel").text = "beta"

    SubElement(item, "pubDate").text = format_pub_date(release.get("published_at"))

    SubElement(
        item,
        "enclosure",
        {
            "url": str(release["url"]),
            "type": "application/octet-stream",
            f"{{{SPARKLE_NAMESPACE}}}edSignature": str(release["signature"]),
            "length": str(release["length"]),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-path", required=True)
    parser.add_argument("--output-path", required=True)
    args = parser.parse_args()

    state = json.loads(Path(args.state_path).read_text())

    register_namespace("sparkle", SPARKLE_NAMESPACE)
    register_namespace("dc", DC_NAMESPACE)

    rss = Element("rss", {"version": "2.0"})
    channel = SubElement(rss, "channel")
    SubElement(channel, "title").text = "ClipKitty Updates"
    SubElement(channel, "link").text = "https://jul-sh.github.io/clipkitty/appcast.xml"
    SubElement(channel, "language").text = "en"

    for release_channel in ("beta", "stable"):
        release = state.get(release_channel)
        if release:
            add_item(channel, release_channel, release)

    xml_bytes = tostring(rss, encoding="utf-8", xml_declaration=True)
    pretty_xml = minidom.parseString(xml_bytes).toprettyxml(indent="  ", encoding="utf-8")
    Path(args.output_path).write_bytes(pretty_xml)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
