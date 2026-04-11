MARKETING_VERSION = "1.12.0"
CURRENT_PROJECT_VERSION = "1"

MACOS_MINIMUM_OS = "14.0"
IOS_MINIMUM_OS = "26.0"

MACOS_BUNDLE_ID = "com.eviljuliette.clipkitty"
MACOS_HARDENED_BUNDLE_ID = "com.eviljuliette.clipkitty.hardened"
IOS_BUNDLE_ID = "com.eviljuliette.clipkitty"
IOS_SHARE_BUNDLE_ID = "com.eviljuliette.clipkitty.share"

SPARKLE_FEED_URL = "https://jul-sh.github.io/clipkitty/appcast.xml"
SPARKLE_PUBLIC_KEY = "9VqfSPPY2Gr8QTYDLa99yJXAFWnHw5aybSbKaYDyCq0="
SPARKLE_OLD_PUBLIC_KEY = ""

# Debug entitlements do not include iCloud/CloudKit, so ENABLE_ICLOUD_SYNC is
# intentionally absent here to avoid a runtime crash from CloudKit code
# executing without matching sandbox entitlements.
MACOS_DEBUG_DEFINES = [
    "ENABLE_BUILD_ATTESTATION_LINK",
    "ENABLE_FILE_CLIPBOARD_ITEMS",
    "ENABLE_LINK_PREVIEWS",
    "ENABLE_SYNTHETIC_PASTE",
]

# Release entitlements include iCloud/CloudKit.
MACOS_RELEASE_DEFINES = MACOS_DEBUG_DEFINES + [
    "ENABLE_ICLOUD_SYNC",
]

MACOS_SPARKLE_DEFINES = MACOS_RELEASE_DEFINES + [
    "ENABLE_SPARKLE_UPDATES",
]

MACOS_APPSTORE_DEFINES = [
    "ENABLE_BUILD_ATTESTATION_LINK",
    "ENABLE_FILE_CLIPBOARD_ITEMS",
    "ENABLE_ICLOUD_SYNC",
    "ENABLE_LINK_PREVIEWS",
]

MACOS_HARDENED_DEFINES = [
    "CLIPKITTY_HARDENED",
    "ENABLE_SYNTHETIC_PASTE",
]

IOS_DEFAULT_DEFINES = [
    "ENABLE_ICLOUD_SYNC",
    "ENABLE_LINK_PREVIEWS",
]

def swift_defines(defines, swift_version = None):
    copts = ["-D{}".format(define) for define in sorted(defines)]
    if swift_version:
        copts.extend(["-swift-version", swift_version])
    return copts
