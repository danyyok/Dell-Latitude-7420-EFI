#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: bash tools/prepare-efi.sh [SERIAL MLB UUID ROM]" >&2
  echo "ROM must be 12 hexadecimal characters without separators." >&2
}

if [[ $# -eq 0 ]]; then
  read -r -p "Serial: " serial
  read -r -p "Board Serial / MLB: " mlb
  read -r -p "SmUUID: " system_uuid
  read -r -p "ROM (12 hex characters): " rom_hex
elif [[ $# -eq 4 ]]; then
  serial="$1"
  mlb="$2"
  system_uuid="$3"
  rom_hex="$4"
else
  usage
  exit 2
fi

if [[ -z "$serial" || -z "$mlb" ]]; then
  echo "Serial and MLB must be non-empty." >&2
  exit 2
fi
if [[ ! "$system_uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  echo "UUID must use the standard 8-4-4-4-12 hexadecimal format." >&2
  exit 2
fi
if [[ ! "$rom_hex" =~ ^[[:xdigit:]]{12}$ ]]; then
  echo "ROM must contain exactly 12 hexadecimal characters, without separators." >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
output="$repo_root/build/EFI"
if [[ -e "$output" || -L "$output" ]]; then
  echo "Refusing to overwrite existing output: $output" >&2
  echo "Move it aside or remove it after making any needed backup, then rerun." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dell-latitude-efi.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
cp -R "$repo_root/EFI" "$work_dir/EFI"
driver_dir="$work_dir/EFI/OC/Drivers"

base_url="https://raw.githubusercontent.com/acidanthera/OcBinaryData/master/Drivers"
curl --fail --location --silent --show-error \
  "$base_url/HfsPlus.efi" --output "$work_dir/HfsPlus.efi"
curl --fail --location --silent --show-error \
  "$base_url/apfs_aligned.efi" --output "$work_dir/apfs_aligned.efi"

printf '%s  %s\n' \
  'A55B5FFF36578864BA6792C4C6369C71F6F35B61DD5A853DDF8583CD36C31D8F' "$work_dir/HfsPlus.efi" \
  '1663FA54103CF808B45FDA3F0385626D1F1899A9ED8258D21A827DB4426ED408' "$work_dir/apfs_aligned.efi" \
  | shasum -a 256 -c -

cp "$work_dir/HfsPlus.efi" "$driver_dir/HfsPlus.efi"
cp "$work_dir/apfs_aligned.efi" "$driver_dir/apfs_aligned.efi"

python3 - \
  "$work_dir/EFI/OC/config.plist" \
  "$work_dir/EFI/OC/config-recovery.plist" \
  "$serial" "$mlb" "$system_uuid" "$rom_hex" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

config_paths = [Path(value) for value in sys.argv[1:3]]
serial, mlb, system_uuid, rom_hex = sys.argv[3:]
rom = bytes.fromhex(rom_hex)
required_drivers = {"HfsPlus.efi", "apfs_aligned.efi"}

for config_path in config_paths:
    config = plistlib.loads(config_path.read_bytes())
    generic = config["PlatformInfo"]["Generic"]
    generic["SystemSerialNumber"] = serial
    generic["MLB"] = mlb
    generic["SystemUUID"] = system_uuid
    generic["ROM"] = rom

    drivers = config["UEFI"]["Drivers"]
    for driver_name in required_drivers:
        matches = [entry for entry in drivers if entry.get("Path") == driver_name]
        if len(matches) != 1:
            raise SystemExit(f"Expected one {driver_name} entry in {config_path}")
        matches[0]["Enabled"] = True

    temporary = config_path.with_name(config_path.name + ".tmp")
    temporary.write_bytes(
        plistlib.dumps(config, fmt=plistlib.FMT_XML, sort_keys=False)
    )
    os.replace(temporary, config_path)
PY

mkdir -p "$repo_root/build"
mv "$work_dir/EFI" "$output"
echo "Prepared EFI written to: $output"
echo "Both configs contain your local SMBIOS values; keep build/EFI private."
