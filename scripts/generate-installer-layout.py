#!/usr/bin/env python3
"""Regenerate Finder metadata; needs ds-store==1.3.3 in a disposable venv, not CI."""
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias, TargetInfo, VolumeInfo
from mac_alias.utils import mac_epoch

output = Path(__file__).resolve().parent.parent / "Artwork/Installer/FinderLayout"
# Use volume-relative paths without a build machine's disk image alias or file IDs.
background = Alias(volume=VolumeInfo("Comet", mac_epoch, b"H+", 5, 0, b"\0\0",
                                    posix_path="/Volumes/Comet"),
                   target=TargetInfo(0, "background.png", 0xFFFFFFFF, 0xFFFFFFFF,
                                     mac_epoch, b"\0\0\0\0", b"\0\0\0\0",
                                     folder_name=".background",
                                     carbon_path="Comet:.background:background.png",
                                     posix_path="/.background/background.png"))
with DSStore.open(str(output), "w+") as store:
    store["."]["vstl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": "{{240, 180}, {660, 388}}", "ShowToolbar": False,
        "ShowSidebar": False, "ShowStatusBar": False, "ShowPathbar": False,
        "ShowTabView": False, "ContainerShowSidebar": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "backgroundImageAlias": background.to_bytes(), "iconSize": 104.0,
        "textSize": 13.0, "labelOnBottom": True, "arrangeBy": "none",
        "showItemInfo": False, "showIconPreview": True,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    store["Comet.app"]["Iloc"] = (180, 188)
    store["Applications"]["Iloc"] = (480, 188)

with DSStore.open(str(output), "r") as store:
    assert store["Comet.app"]["Iloc"] == (180, 188)
    assert store["Applications"]["Iloc"] == (480, 188)
    alias = Alias.from_bytes(store["."]["icvp"]["backgroundImageAlias"])
    assert alias.target.posix_path == "/.background/background.png"
    assert alias.volume.disk_image_alias is None
print("Exported installer Finder layout")
