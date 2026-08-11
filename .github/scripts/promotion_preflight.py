#!/usr/bin/env python3
"""Classify whether an App Store release can be promoted safely."""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from enum import Enum
from pathlib import Path


VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}$")


class PromotionState(str, Enum):
    READY = "ready"
    RECONCILE_EXISTING = "reconcile_existing"
    WAITING_FOR_BETA = "waiting_for_beta"


@dataclass(frozen=True)
class PublishedRelease:
    version: str
    build_number: int
    url: str


def _parse_release(
    state: dict[str, object], channel: str, repository: str
) -> PublishedRelease | None:
    raw_release = state[channel]
    if raw_release is None:
        return None
    if not isinstance(raw_release, dict):
        raise ValueError(f"published {channel} appcast state is not an object")

    version = raw_release.get("version")
    build_number = raw_release.get("build_number")
    url = raw_release.get("url")
    if not isinstance(version, str) or VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError(f"published {channel} version is malformed")
    if (
        not isinstance(build_number, str)
        or not build_number.isascii()
        or not build_number.isdecimal()
    ):
        raise ValueError(f"published {channel} build number is malformed")

    numeric_build = int(build_number)
    if int(version.rsplit(".", 1)[1]) != numeric_build:
        raise ValueError(
            f"published {channel} version/build identity is inconsistent"
        )

    suffix = "-beta" if channel == "beta" else ""
    expected_url = (
        f"https://github.com/{repository}/releases/download/"
        f"v{version}{suffix}/ClipKitty.dmg"
    )
    if url != expected_url:
        raise ValueError(f"published {channel} URL is not canonical")
    return PublishedRelease(version, numeric_build, url)


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def determine_promotion_state(
    state_path: Path,
    appcast_path: Path,
    candidate_version: str,
    repository: str,
) -> PromotionState:
    if VERSION_PATTERN.fullmatch(candidate_version) is None:
        raise ValueError(f"candidate version is malformed: {candidate_version}")

    state = json.loads(state_path.read_text(encoding="utf-8"))
    if not isinstance(state, dict) or "beta" not in state or "stable" not in state:
        raise ValueError("published appcast state must contain beta and stable fields")

    beta = _parse_release(state, "beta", repository)
    stable = _parse_release(state, "stable", repository)
    if stable is None:
        raise ValueError("published appcast state has no stable release")
    if beta is not None and beta.build_number <= stable.build_number:
        raise ValueError("published beta build must be newer than the stable build")

    candidate_build = int(candidate_version.rsplit(".", 1)[1])
    expected_stable = PublishedRelease(
        candidate_version,
        candidate_build,
        f"https://github.com/{repository}/releases/download/"
        f"v{candidate_version}/ClipKitty.dmg",
    )
    if candidate_build < stable.build_number:
        raise ValueError(
            f"refusing to regress stable appcast build "
            f"{stable.build_number} to {candidate_build}"
        )
    if candidate_build == stable.build_number:
        if stable != expected_stable:
            raise ValueError(
                f"stable build {candidate_build} is already bound to another release"
            )
        return PromotionState.RECONCILE_EXISTING

    root = ET.parse(appcast_path).getroot()
    matching_items = []
    for item in (element for element in root.iter() if _local_name(element.tag) == "item"):
        versions = [
            child.text for child in item if _local_name(child.tag) == "version"
        ]
        if versions == [str(candidate_build)]:
            matching_items.append(item)

    if not matching_items:
        if beta is not None and beta.version == candidate_version:
            raise ValueError(
                f"published beta state records {candidate_version}, but its appcast item is missing"
            )
        return PromotionState.WAITING_FOR_BETA
    if len(matching_items) != 1:
        raise ValueError(
            f"published appcast has {len(matching_items)} items for beta build "
            f"{candidate_build}"
        )

    item = matching_items[0]
    child_text = {
        _local_name(child.tag): child.text
        for child in item
        if _local_name(child.tag) != "enclosure"
    }
    if child_text.get("shortVersionString") != candidate_version:
        raise ValueError("published beta appcast has the wrong short version")
    if child_text.get("channel") != "beta":
        raise ValueError("candidate appcast item is not on the beta channel")

    enclosures = [
        child for child in item if _local_name(child.tag) == "enclosure"
    ]
    expected_beta_url = (
        f"https://github.com/{repository}/releases/download/"
        f"v{candidate_version}-beta/ClipKitty.dmg"
    )
    if len(enclosures) != 1 or enclosures[0].get("url") != expected_beta_url:
        raise ValueError("published beta appcast has the wrong enclosure URL")
    return PromotionState.READY


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("state_path", type=Path)
    parser.add_argument("appcast_path", type=Path)
    parser.add_argument("candidate_version")
    parser.add_argument("repository")
    args = parser.parse_args()

    try:
        decision = determine_promotion_state(
            args.state_path,
            args.appcast_path,
            args.candidate_version,
            args.repository,
        )
    except (ET.ParseError, json.JSONDecodeError, OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    print(decision.value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
