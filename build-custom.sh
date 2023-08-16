#!/bin/bash
#
PKGS="xtools ansible python3 cryptsetup openssh curl git vim void-docs-browse xmirror terminus-font vsv vpm"

./mklive.sh -p "$PKGS" -S 'dhcpcd sshd' -I './root'
