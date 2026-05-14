# Golden Dataset

This directory contains deterministic fixtures for validating Symphony workflow behavior.

## `workflow_prompt_cases.json`

The dataset captures representative Linear issue inputs for every active state in the in-repo
`WORKFLOW.md`. Each case includes:

- `id`: stable case identifier
- `purpose`: why the case exists
- `attempt`: optional retry attempt number used when rendering the prompt
- `issue`: normalized `SymphonyElixir.Linear.Issue` fields
- `expect_prompt_contains`: substrings that must appear in the rendered prompt

The dataset is intentionally small. Add cases when the workflow prompt gains a materially different
branch or when an active issue state needs distinct handling.
