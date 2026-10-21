#!/usr/bin/env python3
"""Print an AltStore/SideStore source JSON for the CatWatch release being published.

Usage: make_altstore_source.py <ipa> <version> <build> <owner/repo>
"""
import datetime
import json
import os
import sys

ipa, version, build, repo = sys.argv[1:5]
base = f"https://github.com/{repo}/releases/download/v{version}"

source = {
    "name": "CatWatch",
    "identifier": "com.darkchroma.catwatch.source",
    "iconURL": f"{base}/icon.png",
    "apps": [
        {
            "name": "CatWatch",
            "bundleIdentifier": "com.darkchroma.catwatch",
            "developerName": "DarkChroma",
            "subtitle": "Know when the cat jumps the fence.",
            "localizedDescription": "Turns a spare iPhone into a cat detector that sends Pushover alerts with a snapshot.",
            "iconURL": f"{base}/icon.png",
            "tintColor": "2E7D32",
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                    "downloadURL": f"{base}/CatWatch.ipa",
                    "size": os.path.getsize(ipa),
                    "minOSVersion": "17.0",
                }
            ],
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSCameraUsageDescription": "CatWatch uses the camera to spot your cat entering the no-go zone."
                },
            },
        }
    ],
    "news": [],
}

json.dump(source, sys.stdout, indent=2)
print()
