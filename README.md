# NextStep data

Public, verified institution data for the NextStep app, served by GitHub Pages.

- `manifest.json` says which dataset version is current and its SHA-256 fingerprint.
- `nextstep_dataset_vN.json` is the dataset itself. Each version has its own file name.

Every record lists the official source it was checked against.

## Publishing a new version

1. Update `assets/data/nextstep_dataset.json` in the app project and increase `datasetVersion` by 1.
2. From this folder run:

   ```
   powershell -ExecutionPolicy Bypass -File .\publish_data.ps1
   ```

Phones pick it up within about 12 hours, or straight away with
Profile and settings, Offline data, Check for updates.

## Retiring an institution

Never just delete an institution. Move it to `retiredInstitutions`:

```json
"retiredInstitutions": [
  { "id": "za-ec-example", "name": "Example School", "retiredOn": "2027-02-01",
    "reason": "Merged with Another School" }
]
```

Its ID can never be used again. `publish_data.ps1` refuses to publish if an
institution disappears without being retired.

## What must never go in this repository

Only public institution information. No names of app users, no contact
details of individuals, no API keys or passwords. The app never uploads
anything, and the publish script rejects unexpected fields.
