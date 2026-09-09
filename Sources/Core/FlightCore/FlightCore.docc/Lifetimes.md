# Lifetimes

How long a component lives.

## Overview

Singleton is the only lifetime. A component is built **once**, by the
composition root, and shared for the application's lifetime. There is no
`.scoped` or `.transient`: nothing needed them once per-request state had a
better home, and removing them removed the captive-dependency class of bug
with them. A `scope:` argument naming either is a build error.

## Singleton — the only lifetime

One instance, built during composition, shared by everything. Because a
singleton is shared across every task in the process, it must be `Sendable` —
the compiler enforces it.

A component declares what it needs with `@Inject`, and the composition root
builds it once, in dependency order, wiring those dependencies by type:

```swift
@Service
struct UserService {
    @Inject var repository: UserRepository
}
```

Construction is **eager**, at composition — a `@ConfigValue` that fails to
read, or an initializer that throws, fails the startup that was going to fail
anyway, rather than the first request unlucky enough to touch it.

## Where the other lifetimes went

**Per-request state** rides ``RequestContext`` as a typed value. The
authenticated principal is the worked example: the authentication middleware
writes it into the copy it passes downstream — no registration, no scope. A
per-request object your own code needs is built by the controller, which a
`@Controller`'s route factory constructs fresh per request, or carried on the
context.

**A pooled database connection** is leased for one operation by the repository
that holds the pool (`pool.withConnection { }`), never held for a whole
request — an upgraded WebSocket would otherwise pin a connection for as long
as the tab stayed open.

## Choosing

There is nothing to choose: hold shared, stateless collaborators as the
singletons they are, put per-request state on the request, and lease
per-operation resources where the operation is. If a value feels like it wants
its own lifetime, that is the signal to ask where its state really belongs —
the request, or one operation — rather than to reach for a scope.
