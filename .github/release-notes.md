## Install

1. Download **Relevo.zip** below, unzip it and move **Relevo.app** to your
   Applications folder.
2. Open it. Relevo isn't notarized, so macOS blocks it the first time: open
   **System Settings › Privacy & Security**, scroll to the message about Relevo
   and click **Open Anyway**.

Runs on macOS 14 or later, on Apple silicon and Intel.

To check that this zip was built by the repository's CI from this tag:

```bash
shasum -a 256 -c Relevo.zip.sha256
gh attestation verify Relevo.zip -R Nico-Sanchez/relevo
```
