# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-27

First release of the ABsmartly Elixir SDK. Requires Elixir 1.17+ and Erlang/OTP 25+.

### Added

- **SDK and context.** `ABSmartly` client configuration and an `ABSmartly.Context` GenServer, created synchronously, asynchronously or from pre-fetched context data. The context supports `treatment/2` and `peek/2`, `variable_value/3` and `peek_variable_value/3`, `variable_keys/1`, units and attributes, overrides and custom assignments, goal tracking, publishing, refresh and finalize. It has a custom event handler, and the HTTP client retries failed requests. The README has Phoenix, LiveView and Plug integration examples. (#1)
- **`application` and `environment` audience attributes.** Audience filters are always evaluated with `application` and `environment` set to the names configured in the SDK, so Web Console conditions on either attribute match. An attribute you set with the same name overrides them. They are not published (the collector adds them server-side), and `get_attributes/1` does not return them. `app_version` is never injected. (#2)
- **Assignment rules.** `assign` and `split` rules from an experiment's `assignmentRules` are applied. A matching rule takes precedence over everything except an override. An `assignmentRules` value that is not valid JSON is ignored for that experiment only. Published exposures carry `ruleOverride`: `true` when a rule chose the variant, `false` otherwise. (#3, #4)
- **Semver operators.** `semver_eq`, `semver_gt`, `semver_gte`, `semver_lt` and `semver_lte` work in audience filters and rule conditions. (#3)
- **Versioned `X-Agent`.** Every request sends `X-Agent: absmartly-elixir-sdk/<version>`, and `ABSmartly.HTTP.Client.agent/0` returns that value. (#3)
- **Holdouts.** Holdouts work as in the JavaScript SDK. `ContextData` has a `holdouts` field, `ExperimentData` has `holdout_ids` and `holdout_type`, and there is a new `HoldoutData` struct. Units in a holdout's held-out arm get variant 0 with no exposure of their own for the experiments it covers, unless an override or a matching assignment rule takes precedence. Each covering holdout publishes its own exposure. Two-arm and three-arm holdouts are supported. Payloads without holdouts are unaffected. (#5)
- **Shared variable keys pick one winner.** When several experiments define the same variable key, the SDK follows the Java SDK:
  - The candidates are the experiments with a variant that defines the key, ordered by experiment id. Ids are compared as Java reads them into an `int`.
  - The winner is the first candidate the unit is assigned to, overridden into or given a variant by an assignment rule. If none qualifies, the first held-out candidate supplies its control value; otherwise the caller's default is returned.
  - Only the winner is exposed. A winner whose variant lacks the key returns the default and does not fall through to a later experiment. Holdout exposures are queued before the winner's own.
  - A candidate passed over because its unit was missing, and never exposed, is assigned again once that unit is set (`set_unit/3`, `set_units/2`).
  - `variable_keys/1` lists each key's experiments in id order. (#7)

[1.0.0]: https://github.com/absmartly/elixir-sdk/releases/tag/v1.0.0
