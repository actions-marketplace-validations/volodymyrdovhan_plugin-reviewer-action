# Moodle Plugin Reviewer action

Review your Moodle plugin on every push or pull request with
[Plugin Reviewer](https://reviewer.learningsystemsstudio.com/), and fail the
job when a finding reaches the severity you choose.

The review checks a plugin against the Moodle Plugins Directory and Moodle
Marketplace requirements and coding guidelines (security, privacy API,
language strings, packaging, backup and more). Each run writes a short summary
to the job page; the full report is in your Plugin Reviewer account.

## Setup

1. **Create a token.** Sign in at
   <https://reviewer.learningsystemsstudio.com/?account=1> with GitHub and
   create a CI token under **CI API tokens**. Copy it: it is shown once.
2. **Add the secret.** In your plugin repository, open **Settings → Secrets
   and variables → Actions → New repository secret**, name it
   `PLUGIN_REVIEWER_TOKEN` and paste the token.
3. **Add the workflow.** Create `.github/workflows/plugin-reviewer.yml`:

   ```yaml
   name: Plugin Reviewer

   on:
     push:
       branches: [main]
     pull_request:
     workflow_dispatch:

   jobs:
     review:
       runs-on: ubuntu-latest
       steps:
         - uses: volodymyrdovhan/plugin-reviewer-action@v1
           with:
             token: ${{ secrets.PLUGIN_REVIEWER_TOKEN }}
             fail-on: high
   ```

The repository must be public: the service clones it to review it. For a
private repository use [archive mode](#archive-mode).

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `token` | (required) | Your Plugin Reviewer token, from a secret. |
| `fail-on` | `none` | Fail the job when an active finding is at this severity or higher: `none`, `low`, `medium`, `high`, `blocker`. |
| `review-platform` | `mp` | `mp` reviews against Moodle Marketplace requirements, `pd` against the Moodle Plugins Directory. |
| `listing-type` | `free` | Marketplace listing type: `free` or `paid`. |
| `source-mode` | `repository` | `repository` reviews the public repository at a ref; `archive` uploads plugin folders from the workspace. |
| `repository-url` | this repository | Public GitHub repository to review. |
| `repository-ref` | triggering commit | Commit SHA, branch or tag to review. |
| `plugin-paths` | | Archive mode: plugin folders (each with `version.php`), one per line. |
| `timeout-seconds` | `900` | How long to wait for the review. |
| `reviewer-url` | `https://reviewer.learningsystemsstudio.com` | Service URL, for self-hosted installations. |

## Outputs

| Output | Description |
| --- | --- |
| `submission-id` | Submission ID (comma-separated when several plugins are reviewed). |
| `active-issue-count` | Active findings, after the rules you excluded. |
| `highest-severity` | Highest active severity, or `none`. |

## Archive mode

Use it for private repositories or a repository that holds several plugins.
The job checks out the code and uploads each plugin folder:

```yaml
    steps:
      - uses: actions/checkout@v4
      - uses: volodymyrdovhan/plugin-reviewer-action@v1
        with:
          token: ${{ secrets.PLUGIN_REVIEWER_TOKEN }}
          source-mode: archive
          plugin-paths: |
            local/myplugin
            blocks/myblock
          fail-on: blocker
```

Uploaded archives are deleted from the service after 24 hours.

## Excluding a rule

If a finding does not apply to your plugin, open the report in your account,
mark it as a false positive and choose **Exclude this rule for this plugin**.
Later runs count it as excluded, so it no longer fails the gate.

## Limits

Limits are shared by all your tokens, per plugin: 20 reviews a month, 5 an
hour and 1 at a time by default. Failed runs count toward the hourly limit
only. Your account page shows the current usage.

## Reusable workflow

If you prefer a reusable workflow:

```yaml
jobs:
  review:
    uses: volodymyrdovhan/plugin-reviewer-action/.github/workflows/plugin-reviewer.yml@v1
    with:
      fail-on: high
    secrets:
      PLUGIN_REVIEWER_TOKEN: ${{ secrets.PLUGIN_REVIEWER_TOKEN }}
```

## Versions

Use `@v1` to get fixes automatically, or pin an exact release such as
`@v1.0.0`. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Support

Report problems at
<https://github.com/volodymyrdovhan/plugin-reviewer-tracker/issues>.
Do not post your token in an issue.

## Licence

MIT, see [LICENSE](LICENSE). Plugin Reviewer is not affiliated with or
endorsed by Moodle Pty Ltd. Moodle is a trademark of Moodle Pty Ltd.
