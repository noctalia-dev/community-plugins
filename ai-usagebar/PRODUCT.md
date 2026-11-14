# Product

<!-- impeccable:product-schema 1 -->

## Platform

Native Linux desktop: Noctalia's declarative Luau plugin API. This is neither a
web interface nor an iOS/Android application.

## Users

People checking several AI providers and named accounts while working. Felipe's
primary task is to see multiple accounts together, then inspect a specific one.

## Product Purpose

Show usable quota, balances, reset times and reading freshness without requiring
users to open every provider dashboard.

## Capabilities and Constraints

The ai-usagebar CLI owns authentication, collection, caching, severity and optional
priorities. The plugin presents its reports through one shared service, bar
capsules and a native panel. Selecting an account changes the displayed reading;
it does not switch an agent's login. Priorities remain opt-in.

## Operating Context

The plugin follows the system palette, font and scale. Different widget instances
can follow different accounts. English strings are maintained here; other locales
are managed through Noctalia Translate. Contributions follow the repository README.

## Product Principles

- Compare several accounts without losing provider and account identity.
- Preserve the difference between current, cached, absent and failed readings.
- Keep configuration progressive and use native controls and icons.
- Prefer data and decisions supplied by the CLI over duplicate backend policy.

## Evidence on Hand

Six synthetic Lua suites cover the real scripts. Native inspection uses a separate
fixture plugin without credentials or provider calls. Tests of UI trees supplement
rendered inspection; neither establishes accessibility across every system theme.
