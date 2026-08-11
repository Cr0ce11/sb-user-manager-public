#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

workflow=".github/workflows/ci-release.yml"
preflight_workflow=".github/workflows/release-protection-preflight.yml"
verifier="tools/verify-release-assets.jq"
immutable_check="tools/check-immutable-release-setting.sh"
work="$(mktemp -d)"
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT

[[ -f "$workflow" && ! -L "$workflow" ]]
[[ -f "$preflight_workflow" && ! -L "$preflight_workflow" ]]
[[ -f "$verifier" && ! -L "$verifier" ]]
[[ -f "$immutable_check" && ! -L "$immutable_check" ]]

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
immutable_check_contract="bash tools/check-immutable-release-setting.sh \"${literal_dollar}GITHUB_REPOSITORY\""
immutable_token_contract="GH_TOKEN: ${literal_dollar}{{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}"
release_token_contract="GH_TOKEN: ${literal_dollar}{{ github.token }}"
missing_token_contract="if [[ -z \"${literal_dollar}{GH_TOKEN:-}\" ]]; then"

for release_contract in \
  "$release_view_contract" \
  "$release_create_contract" \
  "$release_draft_contract" \
  "$release_upload_contract" \
  "$release_verify_contract" \
  "$release_filter_contract" \
  "$release_publish_contract" \
  "$immutable_check_contract" \
  "$immutable_token_contract" \
  "$release_token_contract" \
  "$missing_token_contract"; do
  grep -Fq -- "$release_contract" "$workflow" || {
    printf 'immutable release workflow contract is missing: %s\n' "$release_contract" >&2
    exit 1
  }
done

immutable_step="$(sed -n '/- name: Verify immutable release protection/,/- name: Publish immutable release/p' "$workflow")"
publish_step="$(sed -n '/- name: Publish immutable release/,$p' "$workflow")"
grep -Fq "$immutable_token_contract" <<<"$immutable_step"
if grep -Fq "$release_token_contract" <<<"$immutable_step"; then
  echo 'immutable setting preflight must not use the default GitHub token' >&2
  exit 1
fi
grep -Fq "$release_token_contract" <<<"$publish_step"
if grep -Fq "$immutable_token_contract" <<<"$publish_step"; then
  echo 'the dedicated read-only token must not be used to publish a release' >&2
  exit 1
fi
[[ "$(grep -Fc "$immutable_token_contract" "$workflow")" -eq 1 ]]
[[ "$(grep -Fc "$release_token_contract" "$workflow")" -eq 1 ]]

for preflight_contract in \
  'workflow_dispatch:' \
  'contents: read' \
  "$immutable_token_contract" \
  "$missing_token_contract" \
  "$immutable_check_contract"; do
  grep -Fq -- "$preflight_contract" "$preflight_workflow" || {
    printf 'manual release protection preflight contract is missing: %s\n' "$preflight_contract" >&2
    exit 1
  }
done
if grep -Eq 'gh[[:space:]]+release[[:space:]]+(create|upload|edit|delete)' "$preflight_workflow"; then
  echo 'manual release protection preflight must never create or modify a release' >&2
  exit 1
fi

release_create_line="$(grep -nF "$release_create_contract" "$workflow" | cut -d: -f1)"
immutable_check_line="$(grep -nF "$immutable_check_contract" "$workflow" | cut -d: -f1)"
release_upload_line="$(grep -nF "$release_upload_contract" "$workflow" | cut -d: -f1)"
release_verify_line="$(grep -nF "$release_verify_contract" "$workflow" | cut -d: -f1)"
release_publish_line="$(grep -nF "$release_publish_contract" "$workflow" | cut -d: -f1)"
[[ "$immutable_check_line" =~ ^[0-9]+$ && "$release_create_line" =~ ^[0-9]+$ && "$release_upload_line" =~ ^[0-9]+$ &&
   "$release_verify_line" =~ ^[0-9]+$ && "$release_publish_line" =~ ^[0-9]+$ ]]
((immutable_check_line < release_create_line &&
  release_create_line < release_upload_line &&
  release_upload_line < release_verify_line &&
  release_verify_line < release_publish_line)) || {
  echo 'release workflow must create a draft, upload, verify, then publish' >&2
  exit 1
}

grep -Fq "$release_delete_contract" "$workflow"
grep -Fq 'release_published=yes' "$workflow"

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" > "$SB_GH_ARGS_LOG"
case "${SB_IMMUTABLE_FIXTURE:-enabled}" in
  enabled) printf '%s\n' '{"enabled":true}' ;;
  disabled) printf '%s\n' '{"enabled":false}' ;;
  missing) printf '%s\n' '{"status":"available"}' ;;
  malformed) printf '%s\n' 'not-json' ;;
  api-failure) exit 1 ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$work/bin/gh"

immutable_args="$work/immutable-args"
PATH="$work/bin:$PATH" \
  GITHUB_REPOSITORY='DTB201/sb-user-manager-public' \
  SB_GH_ARGS_LOG="$immutable_args" \
  bash "$immutable_check" >/dev/null
grep -Fxq 'api --method GET repos/DTB201/sb-user-manager-public/immutable-releases' "$immutable_args"

for rejected_fixture in disabled missing malformed api-failure; do
  if PATH="$work/bin:$PATH" \
    GITHUB_REPOSITORY='DTB201/sb-user-manager-public' \
    SB_GH_ARGS_LOG="$immutable_args" \
    SB_IMMUTABLE_FIXTURE="$rejected_fixture" \
    bash "$immutable_check" >/dev/null 2>&1; then
    printf 'immutable release preflight accepted fixture: %s\n' "$rejected_fixture" >&2
    exit 1
  fi
done

if PATH="$work/bin:$PATH" GITHUB_REPOSITORY='' SB_GH_ARGS_LOG="$immutable_args" \
  bash "$immutable_check" >/dev/null 2>&1; then
  echo 'immutable release preflight accepted an empty repository name' >&2
  exit 1
fi

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
