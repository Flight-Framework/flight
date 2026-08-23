# Secrets and substitution

Pulling values from the environment, and keeping them out of your logs.

## Overview

`${VAR}` in a configuration file resolves from the process environment at
load time:

```yaml
datasource:
  url: "${DATABASE_URL}"
```

With an optional fallback, for a value that has a sensible default but should
stay overridable:

```yaml
datasource:
  pool_size: ${DB_POOL_SIZE:-10}
```

This is how a file stays committable while the values that vary — and the
values that are secret — come from the deployment platform.

## An unresolved variable fails the load

A `${VAR}` with no fallback, referencing a variable that is not set, fails
the entire load:

```
flight-prod.yaml: key 'datasource.url' references environment variable
'DATABASE_URL' via ${DATABASE_URL}, which is not set. Set it, or use
${DATABASE_URL:-default} to supply a fallback.
```

The alternative would be to let the key fall through to the base layer — and
the base layer is the development file. A production deployment quietly
running against a development database is precisely the outcome worth
refusing to boot over.

## Substituted values are treated as secrets

A value that arrived through `${VAR}` came from the deployment environment,
which is where credentials live. So it is redacted in any diagnostic dump:

```swift
String(reflecting: provider)
// FlightYAML[flight.yaml, 2 keys: db.host=localhost, db.password=<REDACTED>]
```

A literal written into the file is printed as-is — it is already disclosed by
the file it lives in, so hiding it would be theater.

The distinction is recorded at parse time, because the placeholder is gone by
the time anyone reads the resolved value. `FlightYAMLDocument.substitutedKeys`
exposes it if you need it.

> Important: This covers values that came through `${VAR}` in a YAML layer.
> A provider you supply through `additionalProviders` is responsible for
> marking its own values secret — swift-configuration's `ConfigValue` carries
> an `isSecret` flag for exactly that.

## Safe and unsafe logging

``Configuration/description`` names the layers and how many keys each holds,
without printing any of them. It is safe to log unconditionally:

```swift
print(configuration)
// Configuration (environment: prod), 3 providers, highest precedence first:
//   1. EnvironmentVariables[12 values]
//   2. FlightYAML[flight-prod.yaml, 4 keys]
//   3. FlightYAML[flight.yaml, 18 keys]
```

``Configuration/debugDescription`` adds the values, with secrets redacted by
whichever provider holds them.

## Where secrets should actually live

Environment variables, injected by your deployment platform. That is what
`${VAR}` is for, and it is why the environment-variable layer sits at the top
of the precedence order.

For a real secret manager, write a `ConfigProvider` and layer it in:

```swift
let configuration = try Configuration.load(
    additionalProviders: [vaultProvider]
)
```

This package does not implement secret management, and that is a scope
decision rather than an omission — the provider protocol is the seam, and a
provider is a better place for credential fetching, caching, and rotation
than a configuration facade.
