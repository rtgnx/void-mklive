#!/bin/bash
#
PKGS="xtools jq cryptsetup openssh curl git vim void-docs-browse xmirror terminus-font vsv vpm"

./mklive.sh -p "$PKGS" -S 'dhcpcd sshd' -I './root'
