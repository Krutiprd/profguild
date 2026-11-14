#!/bin/sh
# Builds dist/Profguild-<version>.zip containing only the addon folder.
set -e
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^## Version: *//p' Profguild/Profguild.toc | tr -d '\r')
mkdir -p dist
rm -f "dist/Profguild-$VERSION.zip"
zip -qr "dist/Profguild-$VERSION.zip" Profguild -x '*.DS_Store'
echo "dist/Profguild-$VERSION.zip"
