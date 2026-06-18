#!/bin/sh
# bootstrap.sh — fetch submodules and build.
#
# Use this if you cloned without --recurse-submodules, or just to build in
# one step.  Any arguments are passed through to make (e.g. ./bootstrap.sh install).
set -e

cd "$(dirname "$0")"

echo ">> initializing submodules"
git submodule update --init --recursive

echo ">> building"
make "$@"

echo ">> done. Modules in kernel/ and md-kmec/km/, mdadm in mdadm/."
echo "   Install with: sudo make install"
