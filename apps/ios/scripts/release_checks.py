#!/usr/bin/env python3
"""Validate Exerly's release payload before any upload. No credentials are read."""
import argparse
from datetime import datetime, timezone
import ipaddress
from pathlib import Path
import plistlib
import secrets
import subprocess
import tempfile
from urllib.parse import urlparse

BUNDLE = "com.exerly.fitness"
WIDGETS = "com.exerly.fitness.widgets"
WATCH = "com.exerly.fitness.watchkitapp"
TEAM = "9X79V37Q89"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_metadata(info, privacy, version, build, internal_staging=False):
    for key, expected in [("CFBundleIdentifier", BUNDLE),
                          ("CFBundleShortVersionString", version), ("CFBundleVersion", build)]:
        require(info.get(key) == expected, f"Unexpected {key}")
    endpoint = urlparse(info.get("EXERLY_API_BASE_URL", ""))
    if internal_staging:
        require(info.get("EXERLY_BUILD_ENVIRONMENT") == "staging"
                and info.get("EXERLY_API_BASE_URL") == "http://100.80.149.7:39110",
                "Internal staging must use the authorized devbox1 API")
    else:
        require(endpoint.scheme == "https" and endpoint.hostname and not endpoint.username
                and not endpoint.password, "Release API must use public HTTPS without credentials")
        host = endpoint.hostname.lower()
        require(host != "localhost" and not host.endswith((".local", ".ts.net")), "Local release API")
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            address = None
        if address:
            require(address.is_global, "Private release API")
    require(not info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads", False),
            "Release cannot allow arbitrary HTTP")
    require(info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "AppIcon",
            "Missing compiled AppIcon")
    for key in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"]:
        require(bool(info.get(key, "").strip()), f"Missing {key}")
    require(privacy.get("NSPrivacyTracking") is False, "Tracking must be disabled")
    require(not privacy.get("NSPrivacyTrackingDomains"), "Tracking domains are not permitted")
    reasons = {item.get("NSPrivacyAccessedAPIType"): item.get("NSPrivacyAccessedAPITypeReasons", [])
               for item in privacy.get("NSPrivacyAccessedAPITypes", [])}
    require("CA92.1" in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", []),
            "Missing app-only UserDefaults reason")


def validate_profile(profile, bundle=BUNDLE):
    """An App Store profile for `bundle`. The app's must carry HealthKit and Sign in with Apple, the watch app's HealthKit."""
    entitlements = profile.get("Entitlements", {})
    require(profile.get("TeamIdentifier") == [TEAM], "Profile team mismatch")
    require(entitlements.get("application-identifier") == f"{TEAM}.{bundle}", "Profile is for another app")
    require(entitlements.get("get-task-allow") is False, "Profile allows debugging")
    if bundle in (BUNDLE, WATCH):
        require(entitlements.get("com.apple.developer.healthkit") is True, "Profile lacks HealthKit")
    if bundle == BUNDLE:
        require(entitlements.get("com.apple.developer.applesignin") == ["Default"], "Profile lacks Sign in with Apple")
    require(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"),
            "Profile is not for App Store distribution")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime), "Profile expiry missing")
    require(expiry.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc), "Expired profile")


def validate_watch(info, version, build):
    """The embedded watch app belongs to Exerly and matches its version, as App Store Connect requires."""
    for key, expected in [("CFBundleIdentifier", WATCH), ("WKCompanionAppBundleIdentifier", BUNDLE),
                          ("CFBundleShortVersionString", version), ("CFBundleVersion", build)]:
        require(info.get(key) == expected, f"Unexpected watch {key}")
    require("workout-processing" in info.get("WKBackgroundModes", []), "Watch app can't run workouts")
    for key in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"]:
        require(bool(info.get(key, "").strip()), f"Missing watch {key}")


def validate_watch_privacy(privacy):
    """The watch app is its own bundle, so it carries its own privacy manifest for its UserDefaults."""
    require(privacy.get("NSPrivacyTracking") is False, "Watch tracking must be disabled")
    require(not privacy.get("NSPrivacyTrackingDomains"), "Watch tracking domains are not permitted")
    reasons = {item.get("NSPrivacyAccessedAPIType"): item.get("NSPrivacyAccessedAPITypeReasons", [])
               for item in privacy.get("NSPrivacyAccessedAPITypes", [])}
    require("CA92.1" in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", []),
            "Missing watch UserDefaults reason")


def validate_watch_signature(entitlements):
    require(entitlements.get("application-identifier") == f"{TEAM}.{WATCH}", "Watch signature identity mismatch")
    require(entitlements.get("com.apple.developer.healthkit") is True, "Signed watch app lacks HealthKit")
    require(not entitlements.get("get-task-allow", False), "Signed watch app allows debugging")


def read_profile(path):
    # CMS decoding imports the embedded public signer certificates. A locked
    # login keychain cannot accept those imports, even though no private key is
    # needed. Keep that work in a disposable keychain and never unlock or change
    # the user's default keychain or search list.
    with tempfile.TemporaryDirectory(prefix="exerly-profile-check-") as folder:
        keychain = str(Path(folder) / "verification.keychain-db")
        subprocess.run(["security", "create-keychain", "-p", secrets.token_urlsafe(32), keychain],
                       capture_output=True, check=True)
        try:
            decoded = subprocess.run(["security", "cms", "-D", "-k", keychain, "-i", str(path)],
                                     capture_output=True, check=True)
            return plistlib.loads(decoded.stdout)
        finally:
            subprocess.run(["security", "delete-keychain", keychain], capture_output=True, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--unsigned", action="store_true")
    parser.add_argument("--internal-staging", action="store_true")
    args = parser.parse_args()
    app = args.archive / "Products/Applications/Exerly.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    privacy = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
    validate_metadata(info, privacy, args.version, args.build, args.internal_staging)
    require((app / "Assets.car").is_file(), "Compiled assets missing")
    binary = subprocess.run(["strings", str(app / "Exerly")], capture_output=True, text=True, check=True).stdout
    for marker in ["--ui-testing", "EXERLY_TEST_STORE_ID", "EXERLY_TEST_LEGACY_TOKEN", "EXERLY_TEST_ACCOUNT_CONTROLS"]:
        require(marker not in binary, f"Debug fixture marker in release binary: {marker}")
    watch = app / "Watch/ExerlyWatch.app"
    require(watch.is_dir(), "Watch app missing")
    validate_watch(plistlib.loads((watch / "Info.plist").read_bytes()), args.version, args.build)
    require((watch / "PrivacyInfo.xcprivacy").is_file(), "Watch privacy manifest missing")
    validate_watch_privacy(plistlib.loads((watch / "PrivacyInfo.xcprivacy").read_bytes()))
    if not args.unsigned:
        validate_profile(read_profile(app / "embedded.mobileprovision"))
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)],
                             capture_output=True, check=True).stdout
        entitlements = plistlib.loads(raw)
        require(entitlements.get("application-identifier") == f"{TEAM}.{BUNDLE}", "Signature identity mismatch")
        require(entitlements.get("com.apple.developer.healthkit") is True, "Signed app lacks HealthKit")
        require(entitlements.get("com.apple.developer.applesignin") == ["Default"], "Signed app lacks Sign in with Apple")
        require(not entitlements.get("get-task-allow", False), "Signed app allows debugging")
        widgets = app / "PlugIns/ExerlyWidgets.appex"
        require(widgets.is_dir(), "Widgets extension missing")
        validate_profile(read_profile(widgets / "embedded.mobileprovision"), WIDGETS)
        raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(widgets)],
                             capture_output=True, check=True).stdout
        extension = plistlib.loads(raw) if raw.strip() else {}
        require(extension.get("application-identifier") == f"{TEAM}.{WIDGETS}", "Widgets signature identity mismatch")
        require(not extension.get("get-task-allow", False), "Signed widgets allow debugging")
        validate_profile(read_profile(watch / "embedded.mobileprovision"), WATCH)
        raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(watch)],
                             capture_output=True, check=True).stdout
        validate_watch_signature(plistlib.loads(raw) if raw.strip() else {})
    print(f"Verified Exerly {args.version} ({args.build}); {'unsigned' if args.unsigned else 'signed'} archive")


if __name__ == "__main__":
    main()
