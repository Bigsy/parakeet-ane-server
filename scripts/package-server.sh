#!/bin/sh
# Assemble an independently runnable arm64 release directory, including SwiftPM resources.
set -eu
version=${1:?Usage: package-server.sh VERSION [OUTPUT_DIRECTORY]}
output=${2:-.build/distribution/parakeet-ane-server-$version-macos-arm64}
binary_dir=$(swift build -c release --show-bin-path --disable-keychain)
mkdir -p "$output"
install -m 755 "$binary_dir/parakeet-ane-server" "$output/parakeet-ane-server"
for bundle in "$binary_dir"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -Rf "$bundle" "$output/"
done
cp -f LICENSE THIRD_PARTY_NOTICES.md "$output/"
mkdir -p "$output/ThirdPartyLicenses"
for dependency in .build/checkouts/*; do
    [ -d "$dependency" ] || continue
    name=$(basename "$dependency")
    mkdir -p "$output/ThirdPartyLicenses/$name"
    for notice in "$dependency"/LICENSE* "$dependency"/NOTICE*; do
        [ -f "$notice" ] && cp -f "$notice" "$output/ThirdPartyLicenses/$name/" || true
    done
    if [ -d "$dependency/ThirdPartyLicenses" ]; then
        cp -Rf "$dependency/ThirdPartyLicenses" "$output/ThirdPartyLicenses/$name/"
    fi
done
# NeMo is a static binary dependency, so preserve its bundled licenses too.
find .build/artifacts -type f \( -iname '*license*' -o -iname '*notice*' \) -exec cp -f {} "$output/ThirdPartyLicenses/" \;
"$output/parakeet-ane-server" --help >/dev/null
tar -czf "$output.tar.gz" -C "$(dirname "$output")" "$(basename "$output")"
printf '%s\n' "$output"
