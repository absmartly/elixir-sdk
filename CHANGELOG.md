# Changelog

## Unreleased

### Fixed

- Shared variable keys: when two or more running experiments define the same variable key, `Context.variable_value/3` exposed every experiment it checked for the key, including ones the unit was not in (audience mismatch, no unit for the experiment's unit type) and ones that did not end up supplying the value, recording users in experiments they never saw. When the winning experiment's variant did not define the key, the value fell through to a later experiment, so the wrong experiment could win, and candidates were tried in context-data order rather than by experiment id. Anyone with two or more running experiments sharing a variable key is affected. The rule now applied, matching the Java SDK: the candidates are the experiments with any variant that defines the key, by ascending experiment id; the winner is the first one the unit is assigned to, overridden into or given a variant by an assignment rule (else the first held-out one, for its control value; else the default); the winner's variant supplies the value, or the default when it lacks the key; and only the winner is exposed. `Context.peek_variable_value/3` exposes nothing.
