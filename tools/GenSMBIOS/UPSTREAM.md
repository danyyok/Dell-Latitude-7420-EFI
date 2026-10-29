# Vendored GenSMBIOS

This directory contains the Windows and macOS launchers and Python source files from [corpnewt/GenSMBIOS](https://github.com/corpnewt/GenSMBIOS), snapshot `9a446983ec0c6b0fb690dc1cae76c314756a43ee`.

The upstream MIT license is included in `LICENSE`. Trailing whitespace in the vendored Python files was normalized. The tool downloads Acidanthera's `macserial` utility from an OpenCore release when needed. It generates the SMBIOS serial/MLB with `macserial`, and creates UUID and ROM values locally; generated identities are not sent to a service. Downloaded binaries and local settings are ignored.
