#!/bin/bash

sudo rm -rf /etc/systemd/system/st*$1_VM.service
sudo rm -rf /etc/vm_control
rm -rf /home/$1/.config/vm_control/
