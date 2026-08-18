# Generation datasets

Every file here is hand-curated and authored for this project. Nothing is copied from a third-party
dataset, so there is no upstream licence to carry and the files ship inside the app bundle under the
project's own terms.

These are **not** authoritative reference data. They exist to make generated rows read as plausible,
not to be correct. The locality files in particular hold a curated subset of real places with
approximate coordinates, and the Vietnamese one follows the two-tier structure that took effect in
2025 (province then ward, no district level). Do not use any of it as a gazetteer.

Format: UTF-8, one record per line, `#` starts a comment line, blank lines ignored.
`localities.txt` is tab-separated: `city, state, stateCode, postalCode, countryCode, latitude, longitude, timeZone`.

Budget: this directory must stay under 1 MB in total across all locales. `LocaleDataStoreTests`
asserts it.
