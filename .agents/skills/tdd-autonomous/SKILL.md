---
name: tdd-autonomous
description: Autonomous test-driven development for unattended code changes.
---

# Autonomous Test-Driven Development

Use this skill in unattended Build for changes that modify code or combine code
and documentation. Read the issue and inspect the repository to determine the
scope. The `writing-only` and `text-only` labels indicate prose or documentation
only; `docs` alone does not. If the scope is unclear, decide from the task and
repository before coding. Do not omit TDD only because an issue has the `docs`
label. For a task that is clearly limited to prose or static documentation,
record that decision and skip the TDD cycle.

## Choose and record the test boundary

Inspect the behavior and choose the smallest relevant public interface or
interfaces that expose it. Record those interfaces and the behavior to test in
the workpad or task plan before writing tests. Make this decision independently;
do not ask for human approval or wait for a human to approve the test boundary.
Test through public behavior rather than private functions or implementation
details.

## Follow the loop

Work one behavior at a time:

1. Write one focused test through the chosen public interface.
2. Run it and confirm it fails because the behavior is not implemented.
3. Make the smallest implementation that satisfies the test.
4. Run the test again and confirm it passes.
5. Repeat for the next behavior, then run the relevant broader checks.

Do not write all tests before implementation. Keep each test independent of
private structure so it remains useful through refactoring. A passing test is
required evidence for each implementation slice.
