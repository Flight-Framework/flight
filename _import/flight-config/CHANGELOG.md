# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Substituted values are no longer printed in diagnostic dumps.**
  `FlightYAMLProvider`'s debug description printed every value in cleartext,
  including ones resolved from `${VAR}` — which is where credentials come
  from — while the documentation described it as redacting secrets. Values
  that arrived through substitution now render as `<REDACTED>`. Literals
  written into the file are still shown, since the file already discloses
  them.

### Fixed

- **A non-scalar value in a higher-precedence layer no longer falls through
  to a lower one.** A provider holding a key as an array or byte blob
  reported it as *absent*, so resolution continued downward and answered a
  production key from a development layer, silently. Resolution now stops and
  throws `ConfigError.unrepresentableValue`, naming the key, the layer, and
  the shape.
- **A UTF-8 BOM is stripped before parsing.** A BOM-prefixed file — what
  Windows editors write by default — parsed "successfully" into keys prefixed
  with an invisible character, so every lookup reported the key missing from a
  file that visibly contained it.
- **Unreadable-file errors name the actual condition** (`it is a directory,
  not a file`, `the process does not have permission to read it`) instead of
  dumping a raw `NSError` with its domain, code, and `userInfo` blob.
- **Empty path components no longer alias.** `a..b` and `a.b.` both resolved
  to `a.b`, so a typo was indistinguishable from the key it resembled.

### Added

- `ConfigError.unrepresentableValue(key:provider:kind:)` for a key present in
  a layer with no single raw-string form.
- `Configuration.resolveRawValue(for:)`, the throwing form of `rawValue(for:)`.
- `FlightYAMLDocument.substitutedKeys` — the keys whose source text contained
  a `${VAR}` placeholder, recorded at parse time.
- `FlightEnvironment.standard`, listing the four built-in environments.
- DocC catalog with three guides: layering and precedence, the YAML subset,
  and secrets and substitution.

### Changed

- **`FlightEnvironment` is now an extensible `RawRepresentable` struct** rather
  than a closed enum. `dev`, `test`, `staging`, and `prod` remain as static
  members, so existing call sites are unaffected, but a deployment can now add
  its own: `static let qa = FlightEnvironment("qa")`.
- **A non-standard `FLIGHT_ENV` resolves to itself rather than to `dev`.**
  `FLIGHT_ENV=qa` now looks for `flight-qa.yaml`; previously it silently
  loaded development configuration. Collapsing an unrecognized environment to
  `dev` is the same class of silent-wrong-value failure this library exists to
  prevent. An unset or empty value still resolves to `dev`.
- `ConfigError.decodingFailed` carries `targetType` as a `String` rather than
  an `Any.Type`, which lets `ConfigError` and `ConfigLoadError` both conform to
  `Equatable` and `Hashable` — so adopters can assert on them directly.
- Both error types now conform to `LocalizedError`, so `localizedDescription`
  carries the real message rather than a generic Foundation placeholder.
- `CaseIterable.allCases` on `FlightEnvironment` is replaced by
  `FlightEnvironment.standard`; an extensible type cannot enumerate every
  valid value.
