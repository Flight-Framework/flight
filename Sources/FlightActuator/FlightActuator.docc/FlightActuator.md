# ``FlightActuator``

Health, readiness, and introspection endpoints — with an exposure level that
decides what production is allowed to see.

## Overview

Registering the module adds endpoints an orchestrator and an operator both
need:

```
GET /actuator/health     liveness and readiness
GET /actuator/info       build and module metadata
GET /actuator/beans      what the container registered
GET /actuator/routes     the assembled routing table
GET /actuator/config     configuration, with secrets redacted
```

What is actually served depends on ``ActuatorExposure``, and the default
outside development is ``ActuatorExposure/healthOnly`` — an orchestrator gets
its probe and nothing else leaks.

## Exposure is the safety property

- ``ActuatorExposure/disabled`` — nothing is registered at all.
- ``ActuatorExposure/healthOnly`` — health and readiness only. The default
  outside development.
- ``ActuatorExposure/full`` — every endpoint above.

``ActuatorExposure/full`` is **unauthenticated wherever it is enabled**. It
reports registered components, resolved routes and redacted configuration,
which is a useful map of the application to anyone who can reach it. Running
it outside development means putting authentication in front of it — a
middleware, a reverse proxy, or a network boundary. The module does not do
that for you and does not pretend to.

## Health is composed from modules

Each `FlightModule` reports its own `ModuleHealth`; the actuator
aggregates them. A module that cannot reach its database reports so, and
readiness fails without every module needing to know what "ready" means
globally.

## Topics

### Configuration

- ``ActuatorModule``
- ``ActuatorExposure``
- ``ActuatorFormat``
- ``ActuatorConfigurationError``

### Output

- ``ActuatorSnapshot``
