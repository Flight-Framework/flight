# ``FlightActuator``

Health probes and a topology dashboard — with an exposure level that decides
what production is allowed to see.

## Overview

Registering the module adds exactly four routes:

```
GET /actuator/health        every module running?
GET /actuator/health/live   is the process wedged — restart it?
GET /actuator/health/ready  can it serve traffic yet?
GET /actuator               the dashboard: modules and registered components
```

That is the whole surface. There is no `/actuator/info`, `/actuator/beans`,
`/actuator/routes` or `/actuator/config` — this page listed all four for
several releases and none of them ever existed. There are no metrics either,
by decision rather than omission: see `Docs/actuator.md` for why, and reach
for a metrics library when you want metrics.

What is served depends on ``ActuatorExposure``, and the default anywhere that
has not declared itself a development environment is
``ActuatorExposure/healthOnly`` — an orchestrator gets its probes and nothing
else leaks.

## Exposure is the safety property

- ``ActuatorExposure/disabled`` — nothing is registered at all.
- ``ActuatorExposure/healthOnly`` — the three health routes only. The
  default everywhere that has not said otherwise, *including a deployment
  that set nothing*: a default is not a declaration, and a production
  deployment that never set `FLIGHT_ENV` used to get the full dashboard.
- ``ActuatorExposure/full`` — the health routes plus the dashboard.

``ActuatorExposure/full`` is **unauthenticated wherever it is enabled**. It
reports the module list and every registered component's fully-qualified type
name, plus each failed module's error text — a useful map of the application
to anyone who can reach it. Running it outside development means putting
authentication in front of it: a middleware, a reverse proxy, or a network
boundary. The module does not do that for you and does not pretend to.

## Health is composed from modules

Each `FlightModule` gets a ``FlightCore/ModuleHealth`` recorded for it by
Core: `.running` once it configures, `.failed` if its `Service.run()` throws.
The actuator aggregates those and nothing else, so out of the box health
answers "did a module's service die", not "can this module reach its
database". A module that wants to say more calls
`Container.reportHealth(_:forModule:)` on whatever cadence suits
it — a background check, a connection-pool callback — and the probes pick it
up. Nothing here polls and no check runs on the request path, which is what
removes the whole hung-check-and-timeout class of bug.

The two probes differ in one thing, and it is the thing that matters
operationally: a module that has not started yet counts against readiness and
not against liveness, so a slow-starting pod is not restarted into the same
slow start forever.

## Topics

### Configuration

- ``ActuatorModule``
- ``ActuatorExposure``
- ``ActuatorFormat``
- ``ActuatorConfigurationError``

### Output

- ``ActuatorSnapshot``
