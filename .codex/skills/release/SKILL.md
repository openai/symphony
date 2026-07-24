---
name: release
description: Cut a Symphony release by bumping the committed version, landing it, tagging the merged commit, and verifying the Burrito release workflow. Use when asked to release, tag, or retag Symphony.
---

# Release

1. Start from fresh `origin/main` in a clean worktree. Never disturb unrelated
   local changes.
2. Pick the requested version. If none is given, use the next patch after the
   latest `vX.Y.Z` tag.
3. Update `elixir/mix.exs` so `version: "X.Y.Z"` matches the intended tag.
   Search the old version and change other files only when they are true
   release-version sources, not examples.
4. Run `make -C elixir all`, then commit, push, create a PR, and land it.
5. Fetch the merged `main` commit. Verify its `mix.exs` version, then create an
   annotated tag on that exact commit:

   ```sh
   git tag -a vX.Y.Z <merged-commit> -m "Symphony vX.Y.Z"
   git push origin vX.Y.Z
   ```

6. Watch `burrito-release` until it finishes. Verify the build, smoke, and
   release jobs pass and that the GitHub release has all expected assets.

Do not tag an uncommitted or unmerged revision. Do not move a published tag
without explicit user approval.
