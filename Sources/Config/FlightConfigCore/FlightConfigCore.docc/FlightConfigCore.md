# ``FlightConfigCore``

Where configuration values come from, before anything decodes them.

## Overview

``ConfigSource`` is the seam: something that can produce values for keys.
`FlightConfig` layers sources and decodes into typed structures; this module
is the layer underneath, and it is separate so a component can read
configuration without depending on the decoding machinery.

The shipped sources are ``YAMLConfigSource`` and
``EnvironmentVariablesSource``, in that precedence — a file for the defaults,
the environment for whatever the deployment overrides.

## Environment substitution has a policy

A YAML value like `${DATABASE_URL}` is substituted from the environment, and
``EnvironmentSubstitutionPolicy`` decides what happens when the variable is
not set. Failing loudly at load is the useful behaviour: a database URL that
silently became the empty string produces a connection error much later and
much further from the cause.

## Environments

``FlightEnvironment`` is the development/staging/production distinction that
decides which files load and which defaults apply — the actuator's exposure
level, for instance, is stricter outside development because of this type.

``FlightConfigFiles`` names the file layering convention so a deployment does
not have to guess which of `application.yaml` and `application-production.yaml`
wins.

## Testing

``TestConfigSource`` supplies values from a dictionary, so a test can
configure a component without a file on disk or an environment variable
leaking between tests.

## Topics

### The seam

- ``ConfigSource``
- ``ConfigDecodable``

### Sources

- ``YAMLConfigSource``
- ``EnvironmentVariablesSource``
- ``TestConfigSource``

### Environments and files

- ``FlightEnvironment``
- ``FlightConfigFiles``
- ``EnvironmentSubstitutionPolicy``

### Parsing

- ``FlightYAMLDocument``

### Failure

- ``ConfigError``
- ``ConfigLoadError``
