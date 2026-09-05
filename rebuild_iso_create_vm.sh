#!/bin/bash

VBoxManage controlvm debian poweroff 2>/dev/null
sleep 2
VBoxManage unregistervm debian --delete 2>/dev/null
rm -rf disk_images/debian
rm -f debian-*-preseed.iso && echo "VM + ISO cleaned"
