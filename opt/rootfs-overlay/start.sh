#!/bin/sh
# SeedWarden: the app package lives in /opt/src/seedwarden (copied in by build.sh)

cd /opt/src/
export PYTHONPATH=/opt/src

#/usr/bin/python3 -m seedwarden >> /dev/kmsg 2>&1 &  # version that writes output to dmesg
/usr/bin/python3 -m seedwarden &
