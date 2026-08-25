# Lifetimes

How long a component lives, and how to pick.

## Overview

| Lifetime | One instance per | Constructed |
|---|---|---|
| ``Lifetime/singleton`` | application | eagerly, at `freeze()` |
| ``Lifetime/scoped`` | request, or an explicit ``Scope`` | on first resolve in that scope |
| ``Lifetime/transient`` | resolution | every time |

## Singleton

The default, and the right answer for most services. One instance, built
during startup, shared by everything.

```swift
container.register(UserService.self, scope: .singleton) { c in
    UserService(repository: try c.resolve(UserRepository.self))
}
```

Singletons are constructed **eagerly** at ``Container/freeze()``, not lazily
on first use. A factory that throws therefore fails the startup that was
going to fail anyway, rather than the first request unlucky enough to touch
it.

Because a singleton is shared across every task in the process, it must be
`Sendable` — the compiler enforces this at the registration site.

## Scoped

One instance per request. This is where per-request mutable state belongs: a
database connection bound to a transaction, an authenticated principal, a
request-scoped cache.

```swift
container.register(Connection.self, scope: .scoped) { c in
    try c.resolve(DataSource.self).checkout()
}
```

Resolving a `.scoped` component with no active scope **throws**. It does not
quietly fall back to a shared instance, because that is the captive-dependency
bug: a per-request object captured by a singleton, outliving the request it
belonged to, serving the wrong user's data.

```swift
try Scope.withScope { scope in
    let connection = try container.resolve(Connection.self, in: scope)
    // …
}   // scope ends; scoped instances are released
```

Web integrations create the scope per request, so handler code just resolves.

## Transient

A new instance every time. Reach for it when a component genuinely must not
be shared and has no natural scope — a builder, a one-shot operation object.

Transient is the least common of the three. If you are choosing it to avoid
thinking about sharing, `.scoped` is usually the honest answer.

## Choosing

Ask what the component *holds*.

- Holds nothing mutable → **singleton**.
- Holds state belonging to one request → **scoped**.
- Holds state belonging to one operation, with no request in sight →
  **transient**.

If a singleton needs something scoped, that is the captive-dependency shape.
Resolve the scoped component where the request is, and pass it in.
