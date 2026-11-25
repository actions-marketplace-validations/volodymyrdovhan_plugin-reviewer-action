# Changelog

## [1.0.0] - 2026-11-25

### Added
- Composite action that queues a Plugin Reviewer review, waits for it, writes
  a job summary and fails the job at a chosen severity (`fail-on`).
- Repository mode (public repository at a commit, branch or tag) and archive
  mode (plugin folders uploaded from the workspace).
- Clear errors for a rejected token and for reached usage limits.
- Reusable workflow that wraps the action.
