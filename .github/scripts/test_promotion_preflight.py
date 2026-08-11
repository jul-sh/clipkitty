#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from promotion_preflight import PromotionState, determine_promotion_state


REPOSITORY = "jul-sh/clipkitty"


def release(version: str, channel: str) -> dict[str, str]:
    suffix = "-beta" if channel == "beta" else ""
    return {
        "version": version,
        "build_number": version.rsplit(".", 1)[1],
        "url": (
            f"https://github.com/{REPOSITORY}/releases/download/"
            f"v{version}{suffix}/ClipKitty.dmg"
        ),
    }


def appcast_item(version: str, channel: str = "beta") -> str:
    build_number = version.rsplit(".", 1)[1]
    channel_element = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
    return f"""
    <item>
      <sparkle:version>{build_number}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      {channel_element}
      <enclosure url="https://github.com/{REPOSITORY}/releases/download/v{version}-beta/ClipKitty.dmg" />
    </item>
    """


class PromotionPreflightTests(unittest.TestCase):
    def decide(
        self,
        candidate: str,
        *,
        beta: str | None = "1.13.1458",
        stable: str = "1.13.1428",
        items: list[str] | None = None,
    ) -> PromotionState:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state_path = root / "appcast-state.json"
            appcast_path = root / "appcast.xml"
            state_path.write_text(
                json.dumps(
                    {
                        "beta": release(beta, "beta") if beta else None,
                        "stable": release(stable, "stable"),
                    }
                ),
                encoding="utf-8",
            )
            appcast_path.write_text(
                "<rss xmlns:sparkle=\"https://sparkle-project.org/xml-namespaces/sparkle\"><channel>"
                + "".join(items or [])
                + "</channel></rss>",
                encoding="utf-8",
            )
            return determine_promotion_state(
                state_path, appcast_path, candidate, REPOSITORY
            )

    def test_existing_stable_is_reconciled(self) -> None:
        self.assertEqual(
            self.decide("1.13.1428"), PromotionState.RECONCILE_EXISTING
        )

    def test_unpublished_beta_is_a_waiting_state(self) -> None:
        self.assertEqual(
            self.decide("1.13.1460"), PromotionState.WAITING_FOR_BETA
        )

    def test_exact_published_beta_is_ready(self) -> None:
        self.assertEqual(
            self.decide(
                "1.13.1460",
                beta="1.13.1460",
                items=[appcast_item("1.13.1460")],
            ),
            PromotionState.READY,
        )

    def test_candidate_item_with_wrong_channel_fails(self) -> None:
        with self.assertRaisesRegex(ValueError, "not on the beta channel"):
            self.decide(
                "1.13.1460",
                beta="1.13.1460",
                items=[appcast_item("1.13.1460", channel="stable")],
            )

    def test_state_item_mismatch_fails_instead_of_waiting(self) -> None:
        with self.assertRaisesRegex(ValueError, "appcast item is missing"):
            self.decide("1.13.1460", beta="1.13.1460")

    def test_stable_regression_fails(self) -> None:
        with self.assertRaisesRegex(ValueError, "refusing to regress"):
            self.decide("1.13.1407")


if __name__ == "__main__":
    unittest.main()
