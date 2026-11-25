#!/usr/bin/env bash
# Queues a Plugin Reviewer review, waits for it, writes a job summary and
# applies the fail-on gate. Inputs arrive as environment variables (action.yml).
set -euo pipefail

reviewer_url="${REVIEWER_URL%/}"
repository_url="${REQUESTED_REPOSITORY_URL:-https://github.com/${CALLER_REPOSITORY}}"
repository_ref="${REQUESTED_REPOSITORY_REF:-${CALLER_SHA}}"
timeout_seconds="${TIMEOUT_SECONDS:-900}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/null}"
output_file="${GITHUB_OUTPUT:-/dev/null}"
work_dir="${RUNNER_TEMP:-$(mktemp -d)}"

fail() {
  echo "::error title=Plugin Reviewer::$1" >&2
  exit 1
}

[[ -n "${REVIEWER_TOKEN:-}" ]] || fail "The token input is empty. Create a token on your Plugin Reviewer account page and pass it from a repository secret."

case "${FAIL_ON:-none}" in
  none) threshold=5 ;;
  any | low) threshold=1 ;;
  medium) threshold=2 ;;
  high) threshold=3 ;;
  blocker) threshold=4 ;;
  *) fail "Invalid fail-on value '${FAIL_ON}'. Use none, low, medium, high or blocker." ;;
esac

# api METHOD PATH [curl args...]: prints the response body, or fails with the
# API's own message and a hint for the common status codes.
api() {
  local method="$1" path="$2"
  shift 2
  local body_file="$work_dir/plugin-reviewer-response.json" status detail
  status="$(curl --silent --show-error --output "$body_file" --write-out '%{http_code}' \
    --request "$method" "$reviewer_url$path" \
    --header "Authorization: Bearer $REVIEWER_TOKEN" "$@")" || fail "Could not reach $reviewer_url."
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    detail="$(jq -r 'if (.detail | type) == "string" then .detail else (.detail // . | tostring) end' "$body_file" 2>/dev/null || head -c 300 "$body_file")"
    case "$status" in
      401 | 403) fail "Token rejected ($status): $detail. Check that the secret holds an active token with ci:submit and ci:read." ;;
      429) fail "Usage limit reached ($status): $detail. See the CI usage section on your account page." ;;
      *) fail "Plugin Reviewer API returned $status: $detail" ;;
    esac
  fi
  cat "$body_file"
}

declare -a submission_ids polling_urls
case "${SOURCE_MODE:-repository}" in
  repository)
    request_body="$(jq -n \
      --arg repository_url "$repository_url" \
      --arg repository_ref "$repository_ref" \
      --arg review_platform "$REVIEW_PLATFORM" \
      --arg marketplace_listing_type "$LISTING_TYPE" \
      '{repository_url: $repository_url, repository_ref: $repository_ref, review_platform: $review_platform, marketplace_listing_type: $marketplace_listing_type}')"
    created="$(api POST /api/v1/ci/reviews/repository --header "Content-Type: application/json" --data "$request_body")"
    submission_ids+=("$(jq -er '.submission_id' <<<"$created")")
    polling_urls+=("$(jq -er '.polling_url' <<<"$created")")
    ;;
  archive)
    [[ -n "${PLUGIN_PATHS//[[:space:]]/}" ]] || fail "plugin-paths is required in archive mode."
    while IFS= read -r plugin_path; do
      plugin_path="${plugin_path#"${plugin_path%%[![:space:]]*}"}"
      plugin_path="${plugin_path%"${plugin_path##*[![:space:]]}"}"
      [[ -z "$plugin_path" ]] && continue
      [[ -f "$plugin_path/version.php" ]] || fail "Plugin path has no version.php: $plugin_path (did the job run actions/checkout first?)"
      archive_file="$work_dir/plugin-reviewer-${#submission_ids[@]}.zip"
      rm -f "$archive_file"
      (cd "$plugin_path" && zip -qr "$archive_file" . -x '.git/*')
      created="$(api POST /api/v1/ci/reviews/archive \
        --form "file=@${archive_file};type=application/zip" \
        --form-string "repository_url=$repository_url" \
        --form-string "repository_ref=$repository_ref" \
        --form-string "plugin_path=$plugin_path" \
        --form-string "review_platform=$REVIEW_PLATFORM" \
        --form-string "marketplace_listing_type=$LISTING_TYPE")"
      submission_ids+=("$(jq -er '.submission_id' <<<"$created")")
      polling_urls+=("$(jq -er '.polling_url' <<<"$created")")
    done <<<"$PLUGIN_PATHS"
    ;;
  *) fail "Invalid source-mode '${SOURCE_MODE}'. Use repository or archive." ;;
esac

((${#submission_ids[@]} > 0)) || fail "No plugin paths were submitted."
echo "submission-id=$(IFS=,; echo "${submission_ids[*]}")" >>"$output_file"
echo "Queued: ${submission_ids[*]} ($repository_url @ $repository_ref)"

deadline=$((SECONDS + timeout_seconds))
total_active=0
highest_severity="none"
severity=0
{
  echo "## Plugin Reviewer"
  echo
} >>"$summary_file"

for index in "${!submission_ids[@]}"; do
  submission_id="${submission_ids[$index]}"
  polling_url="${polling_urls[$index]}"
  while true; do
    ((SECONDS < deadline)) || fail "Timed out after ${timeout_seconds}s waiting for $submission_id."
    result="$(api GET "$polling_url")"
    review_status="$(jq -er '.status' <<<"$result")"
    case "$review_status" in
      queued | running) sleep 10 ;;
      succeeded) break ;;
      *) fail "Review $submission_id $review_status: $(jq -r '.error // "review did not complete"' <<<"$result")" ;;
    esac
  done

  active_count="$(jq -er '.active_issue_count // 0' <<<"$result")"
  total_count="$(jq -er '.total_issue_count // 0' <<<"$result")"
  suppressed_count="$(jq -er '.suppressed_issue_count // 0' <<<"$result")"
  result_severity="$(jq -r '
    [.findings[]?.severity | ascii_downcase] as $values |
    if ($values | index("blocker")) then "blocker"
    elif ($values | index("high")) then "high"
    elif ($values | index("medium")) then "medium"
    elif ($values | index("low")) then "low"
    else "none" end' <<<"$result")"
  account_review_url="$(jq -r '.account_review_url // empty' <<<"$result")"
  total_active=$((total_active + active_count))
  case "$result_severity" in none) rank=0 ;; low) rank=1 ;; medium) rank=2 ;; high) rank=3 ;; blocker) rank=4 ;; esac
  if ((rank > severity)); then
    highest_severity="$result_severity"
    severity=$rank
  fi

  echo "$submission_id: $active_count active / $suppressed_count excluded / $total_count total, highest active severity: $result_severity"
  [[ -n "$account_review_url" ]] && echo "Report: $account_review_url"
  {
    echo "- Submission: \`$submission_id\`"
    echo "- Findings: $active_count active / $suppressed_count excluded / $total_count total"
    echo "- Highest active severity: \`$result_severity\`"
    if [[ -n "$account_review_url" ]]; then
      echo "- Report (sign in to view): $account_review_url"
    fi
    echo
  } >>"$summary_file"
done

echo "active-issue-count=$total_active" >>"$output_file"
echo "highest-severity=$highest_severity" >>"$output_file"

if ((severity >= threshold && severity > 0)); then
  fail "Gate failed: highest active severity is $highest_severity (fail-on: ${FAIL_ON})."
fi
