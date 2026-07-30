#!/usr/bin/env bash
# Source me. udev rule text for CM108-family (C-Media, vendor 0d8c) PTT
# devices — the single place the rule format lives.
#
# Two consumers need the IDENTICAL rule text: svx.tmpl's PTT wizard
# sources this file FROM THE STAGED PAYLOAD (~/.svxlink/payload/lib/
# udev-rule.sh — the wizard runs on boxes with no installer tree, exactly
# like every other payload script), and scripts/test/check-udev-rule.sh
# sources it from the repo, so the production rule and its test can never
# drift apart.
#
# Why a udev rule is MANDATORY for CM108 PTT (not an optimization):
# /dev/hidraw* nodes are created root:root 0600 with no group at all, so
# the quadlet's GroupAdd=keep-groups — which carries the host user's
# supplementary groups into the container — has nothing to ride on; only
# udev can chgrp the node. GROUP="audio" reuses a group the installer
# already joined (no extra usermod), and SYMLINK+="svxlink-ptt" gives the
# quadlet a name that survives hidraw renumbering across replugs — its
# AddDevice= points at /dev/svxlink-ptt, never at a raw /dev/hidrawN.

# udev_rule_cm108 IDPRODUCT [KERNELS]
#   Print exactly one udev rule line.
#   IDPRODUCT: the 4-hex product id as udev reports it (e.g. 013c) —
#     matched explicitly rather than matching all of vendor 0d8c, because
#     0d8c also makes plain (non-GPIO) audio dongles and a rule grabbing
#     every C-Media hidraw node would symlink the wrong device on hosts
#     that carry both.
#   KERNELS: optional USB port path (e.g. 3-1.4). With several IDENTICAL
#     adapters present, idVendor/idProduct match all of them and the
#     symlink would flap between devices across boots; pinning KERNELS to
#     the hub position disambiguates (and means: keep the PTT adapter in
#     that physical port). The wizard passes it only when it detected
#     more than one CM108.
udev_rule_cm108() {
    local idproduct=$1 kernels=${2:-}
    if [[ -n "$kernels" ]]; then
        printf 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0d8c", ATTRS{idProduct}=="%s", KERNELS=="%s", GROUP="audio", MODE="0660", SYMLINK+="svxlink-ptt"\n' \
            "$idproduct" "$kernels"
    else
        printf 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0d8c", ATTRS{idProduct}=="%s", GROUP="audio", MODE="0660", SYMLINK+="svxlink-ptt"\n' \
            "$idproduct"
    fi
}
