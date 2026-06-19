#!/usr/bin/env bash
# Create GitHub issues for repo-review FINDINGS (1:1 with docs/repo-review/index.html).
# Idempotent: skips findings whose title already contains "[FINDING-ID]".
#
# Usage:
#   ./scripts/create-repo-review-issues.sh <EPIC_ISSUE_NUMBER>
#
# Prerequisites: gh auth login; run from repo root.

set -euo pipefail

REPO="${REPO:-CloudbrokerAz/mac-speech-to-text}"
EPIC="${1:-${EPIC_ISSUE:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FINDINGS_HTML="${ROOT}/docs/repo-review/index.html"
REPORT_URL="https://github.com/${REPO}/blob/main/docs/repo-review/index.html"

if [[ -z "${EPIC}" ]]; then
  echo "Usage: $0 <EPIC_ISSUE_NUMBER>" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

if [[ ! -f "${FINDINGS_HTML}" ]]; then
  echo "Missing ${FINDINGS_HTML}" >&2
  exit 1
fi

ensure_label() {
  local name="$1"
  local color="$2"
  local description="$3"
  if gh label list --repo "${REPO}" --limit 500 --json name --jq '.[].name' | grep -Fxq "${name}"; then
    return 0
  fi
  gh label create "${name}" --repo "${REPO}" --color "${color}" --description "${description}" 2>/dev/null || true
}

ensure_all_labels() {
  ensure_label "repo-review" "5319E7" "Repo review remediation finding"
  ensure_label "phase-1" "B60205" "Phase 1: critical + high severity"
  ensure_label "backlog" "C5DEF5" "Phase 2: medium + low severity"
  ensure_label "severity:critical" "B60205" "Critical severity finding"
  ensure_label "severity:high" "D93F0B" "High severity finding"
  ensure_label "severity:medium" "FBCA04" "Medium severity finding"
  ensure_label "severity:low" "0E8A16" "Low severity finding"
  ensure_label "in-progress" "1D76DB" "Remediation work in progress"
  ensure_label "concurrency" "5319E7" "Concurrency dimension"
  ensure_label "performance" "F9D0C4" "Performance dimension"
  ensure_label "architecture" "C2E0C6" "Architecture dimension"
  ensure_label "effort:S" "C5DEF5" "Small effort"
  ensure_label "effort:M" "BFDADC" "Medium effort"
  ensure_label "effort:L" "E99695" "Large effort"
}

dim_to_label() {
  case "$1" in
    security) echo "security" ;;
    concurrency) echo "concurrency" ;;
    performance) echo "performance" ;;
    architecture) echo "architecture" ;;
    testing) echo "tests" ;;
    *) echo "repo-review" ;;
  esac
}

strip_html_codes() {
  python3 -c 'import sys,re; t=sys.stdin.read(); t=re.sub(r"</?code>", "`", t); print(t, end="")'
}

FINDINGS_JSON="$(FINDINGS_HTML="${FINDINGS_HTML}" python3 << 'PY'
import json, re, os
path = os.environ["FINDINGS_HTML"]
text = open(path, encoding="utf-8").read()
m = re.search(r"const FINDINGS = \[(.*?)\n\];", text, re.DOTALL)
if not m:
    sys.exit("FINDINGS array not found")
block = m.group(1)
pat = re.compile(
    r'\{\s*id:"(?P<id>[^"]+)"\s*,\s*dim:"(?P<dim>[^"]+)"\s*,\s*sev:"(?P<sev>[^"]+)"\s*,\s*cat:"(?P<cat>(?:\\.|[^"\\])*)"\s*,\s*effort:"(?P<effort>[^"]*)"'
    r'[\s\S]*?\n\s*title:"(?P<title>(?:\\.|[^"\\])*)"[\s\S]*?\n\s*loc:"(?P<loc>(?:\\.|[^"\\])*)"[\s\S]*?\n\s*ev:"(?P<ev>(?:\\.|[^"\\])*)"[\s\S]*?\n\s*fix:"(?P<fix>(?:\\.|[^"\\])*)"',
    re.MULTILINE,
)
rows = [mo.groupdict() for mo in pat.finditer(block)]
if len(rows) != 70:
    sys.exit(f"expected 70 findings, got {len(rows)}")
print(json.dumps(rows))
PY
)"

echo "Ensuring GitHub labels..."
ensure_all_labels

echo "Loading existing repo-review issues..."
EXISTING_JSON="$(gh issue list --repo "${REPO}" --label repo-review --state all --limit 200 --json number,title 2>/dev/null || echo '[]')"

declare -a CREATED_LINES=()
CREATED_COUNT=0
SKIPPED_COUNT=0

while IFS= read -r row; do
  id="$(echo "${row}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  title_raw="$(echo "${row}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
  sev="$(echo "${row}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sev"])')"
  effort="$(echo "${row}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["effort"])')"
  dim="$(echo "${row}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["dim"])')"
  loc="$(echo "${row}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["loc"])')"
  ev="$(echo "${row}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ev"])')"
  fix="$(echo "${row}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fix"])')"

  issue_title="[${id}] ${title_raw}"
  marker="[${id}]"

  existing_num="$(echo "${EXISTING_JSON}" | python3 -c "
import json, sys
marker = sys.argv[1]
for item in json.load(sys.stdin):
    if marker in item.get('title', ''):
        print(item['number'])
        break
" "${marker}")"

  if [[ -n "${existing_num}" ]]; then
    echo "Skip ${id} (existing #${existing_num})"
    CREATED_LINES+=("| ${id} | #${existing_num} | ${issue_title} |")
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  dim_label="$(dim_to_label "${dim}")"
  labels=("repo-review" "${dim_label}" "severity:${sev}")
  if [[ "${sev}" == "critical" || "${sev}" == "high" ]]; then
    labels+=("phase-1")
  else
    labels+=("backlog")
  fi
  if [[ "${effort}" == "S" || "${effort}" == "M" || "${effort}" == "L" ]]; then
    labels+=("effort:${effort}")
  fi
  if [[ "${id}" == "PRF-2" ]]; then
    labels+=("blocked")
  fi

  label_args=()
  for lb in "${labels[@]}"; do
    label_args+=(--label "${lb}")
  done

  anchor="${dim}"
  [[ "${dim}" == "testing" ]] && anchor="testing"

  ev_md="$(printf '%s' "${ev}" | strip_html_codes)"
  fix_md="$(printf '%s' "${fix}" | strip_html_codes)"

  extra_blocked=""
  if [[ "${id}" == "PRF-2" ]]; then
    extra_blocked=$'\n\n> **Blocked:** \`blocked: product-sign-off\` — do not implement until explicit approval (locked mlx-lifecycle decision).\n'
  fi

  body="$(cat <<BODY_EOF
## Finding
- **ID:** ${id}
- **Severity:** ${sev} · **Effort:** ${effort}
- **Location:** \`${loc}\`
- **Report:** [docs/repo-review/index.html#${anchor}](${REPORT_URL})

## Evidence
${ev_md}

## Fix
${fix_md}
${extra_blocked}
## Acceptance criteria
- [ ] Fix applied at cited location(s)
- [ ] Tests added/updated per \`.claude/references/testing-conventions.md\`
- [ ] \`swift test --parallel\` passes (filtered to relevant suite)
- [ ] \`swiftlint lint --strict\` clean on touched files
- [ ] \`pre-commit run --files <touched>\` passes
- [ ] Three security-review agents run pre-PR (see workflow below)
- [ ] PR opened with \`Closes #<this-issue>\`

## Agent context
Load from AGENTS.md Topic Router:
- Security/PHI → \`.claude/references/phi-handling.md\`
- Concurrency → \`.claude/references/concurrency.md\`
- Cliniko HTTP → \`.claude/references/cliniko-api.md\`
- MLX/model → \`.claude/references/mlx-lifecycle.md\`
- Tests → \`.claude/references/testing-conventions.md\`

Parent EPIC: #${EPIC}
BODY_EOF
)"

  echo "Creating ${id}..."
  new_url="$(gh issue create --repo "${REPO}" --title "${issue_title}" "${label_args[@]}" --body "${body}")"
  new_num="${new_url##*/}"
  CREATED_LINES+=("| ${id} | #${new_num} | ${issue_title} |")
  CREATED_COUNT=$((CREATED_COUNT + 1))
  EXISTING_JSON="$(echo "${EXISTING_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data.append({'number': int(sys.argv[1]), 'title': sys.argv[2]})
print(json.dumps(data))
" "${new_num}" "${issue_title}")"
done < <(echo "${FINDINGS_JSON}" | python3 -c 'import json,sys; [print(json.dumps(x)) for x in json.load(sys.stdin)]')

TABLE_HEADER=$'## Child issue mapping\n\n| Finding | Issue | Title |\n|---------|-------|-------|\n'
TABLE_BODY="$(printf '%s\n' "${CREATED_LINES[@]}")"
TABLE_FOOTER=$'\n\n_Generated by `scripts/create-repo-review-issues.sh`._\n'

COMMENT_BODY="${TABLE_HEADER}${TABLE_BODY}${TABLE_FOOTER}"

echo "Posting mapping comment on EPIC #${EPIC}..."
gh issue comment "${EPIC}" --repo "${REPO}" --body "${COMMENT_BODY}"

echo "Done. Created ${CREATED_COUNT} new issues; ${SKIPPED_COUNT} already existed (total mapped: 70)."
