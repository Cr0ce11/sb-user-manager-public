#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

workflow=".github/workflows/ci-release.yml"
verifier="tools/verify-release-assets.jq"
work="$(mktemp -d)"
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT

[[ -f "$workflow" && ! -L "$workflow" ]]
[[ -f "$verifier" && ! -L "$verifier" ]]

if grep -Fq -- '--clobber' "$workflow"; then
  echo 'published release assets must never be overwritten' >&2
  exit 1
fi

literal_dollar='$'
release_view_contract="if gh release view \"${literal_dollar}tag\" >/dev/null 2>&1; then"
release_create_contract="gh release create \"${literal_dollar}tag\" \\"
release_draft_contract="            --draft \\"
release_upload_contract="gh release upload \"${literal_dollar}tag\" \"${literal_dollar}{assets[@]}\""
release_verify_contract="gh release view \"${literal_dollar}tag\" --json tagName,isDraft,isPrerelease,assets"
release_filter_contract='-f tools/verify-release-assets.jq'
release_publish_contract="gh release edit \"${literal_dollar}tag\" --draft=false --latest"
release_delete_contract="gh release delete \"${literal_dollar}tag\" --yes"

for release_contract in \
  "$release_view_contract" \
  "$release_create_contract" \
  "$release_draft_contract" \
  "$release_upload_contract" \
  "$release_verify_contract" \
  "$release_filter_contract" \
  "$release_publish_contract"; do
  grep -Fq -- "$release_contract" "$workflow" || {
    printf 'immutable release workflow contract is missing: %s\n' "$release_contract" >&2
    exit 1
  }
done

release_create_line="$(grep -nF "$release_create_contract" "$workflow" | cut -d: -f1)"
release_upload_line="$(grep -nF "$release_upload_contract" "$workflow" | cut -d: -f1)"
release_verify_line="$(grep -nF "$release_verify_contract" "$workflow" | cut -d: -f1)"
release_publish_line="$(grep -nF "$release_publish_contract" "$workflow" | cut -d: -f1)"
[[ "$release_create_line" =~ ^[0-9]+$ && "$release_upload_line" =~ ^[0-9]+$ &&
   "$release_verify_line" =~ ^[0-9]+$ && "$release_publish_line" =~ ^[0-9]+$ ]]
((release_create_line < release_upload_line &&
  release_upload_line < release_verify_line &&
  release_verify_line < release_publish_line)) || {
  echo 'release workflow must create a draft, upload, verify, then publish' >&2
  exit 1
}

grep -Fq "$release_delete_contract" "$workflow"
grep -Fq 'release_published=yes' "$workflow"

manager_digest='sha256:1111111111111111111111111111111111111111111111111111111111111111'
checksum_digest='sha256:2222222222222222222222222222222222222222222222222222222222222222'

jq -n \
  --arg manager_digest "$manager_digest" \
  --arg checksum_digest "$checksum_digest" '
  {
    tagName: "v9.9.9",
    isDraft: true,
    isPrerelease: false,
    assets: [
      {name: "sb-user-manager.sh", digest: $manager_digest},
      {name: "sb-user-manager.sh.sha256", digest: $checksum_digest}
    ]
  }
' >"$work/valid.json"

verify_fixture() {
  jq -e \
    --arg tag v9.9.9 \
    --arg manager_digest "$manager_digest" \
    --arg checksum_digest "$checksum_digest" \
    -f "$verifier" "$1" >/dev/null
}

verify_fixture "$work/valid.json"

jq '.isDraft = false' "$work/valid.json" >"$work/published.json"
if verify_fixture "$work/published.json"; then
  echo 'already published release must be rejected during draft verification' >&2
  exit 1
fi

jq '.assets[0].digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$work/valid.json" >"$work/wrong-digest.json"
if verify_fixture "$work/wrong-digest.json"; then
  echo 'wrong release asset digest must be rejected' >&2
  exit 1
fi

jq 'del(.assets[1])' "$work/valid.json" >"$work/missing.json"
if verify_fixture "$work/missing.json"; then
  echo 'missing release asset must be rejected' >&2
  exit 1
fi

jq '.assets += [{name:"unexpected.txt", digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' \
  "$work/valid.json" >"$work/extra.json"
if verify_fixture "$work/extra.json"; then
  echo 'unexpected release asset must be rejected' >&2
  exit 1
fi

jq '.tagName = "v9.9.8"' "$work/valid.json" >"$work/wrong-tag.json"
if verify_fixture "$work/wrong-tag.json"; then
  echo 'wrong release tag must be rejected' >&2
  exit 1
fi

echo 'immutable release workflow checks passed'
