#!/usr/bin/env bash
set -euo pipefail

manifest=.github/windows-preview.json
version=$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+-rc\\.[0-9]+$"))' "$manifest")
source=$(jq -er '.commit | select(test("^[0-9a-f]{40}$"))' "$manifest")
tag="v$version"
notes="releases/$tag.md"
api="repos/$GITHUB_REPOSITORY"
test -s "$notes"

platforms=(windows)
if jq -e 'has("macos")' "$manifest" >/dev/null; then
  platforms+=(macos)
fi

release="$RUNNER_TEMP/release.json"
gh api "$api/git/matching-refs/tags/$tag" | jq -e --arg tag "refs/tags/$tag" --arg sha "$source" '
  all(.[] | select(.ref == $tag); .object.sha == $sha)'
if gh release view "$tag" --json databaseId,targetCommitish,isDraft,isPrerelease,assets > "$release"; then
  jq -e --arg sha "$source" '.targetCommitish == $sha and .isPrerelease' "$release"
else
  echo '{"assets":[],"isDraft":true}' > "$release"
fi

cd "$RUNNER_TEMP"
expected='[]'
for platform in "${platforms[@]}"; do
  if [[ "$platform" == windows ]]; then
    name="WordMath-$version-windows-x64-setup.exe"
    section=.
    workflow=windows-package.yml
  else
    name="WordMath-$version-macOS-arm64.zip"
    section=.macos
    workflow=macos-package.yml
  fi
  package=$(jq -e "$section" "$GITHUB_WORKSPACE/$manifest")
  checksum=$(jq -er '.sha256 | select(test("^[a-f0-9]{64}$"))' <<< "$package")
  run=$(jq -er '.run_id | numbers' <<< "$package")
  artifact=$(jq -er '.artifact_id | numbers' <<< "$package")
  expected=$(jq -c --arg n "$name" --arg d "sha256:$checksum" '. + [{name:$n,digest:$d}]' <<< "$expected")
  if jq -e --arg n "$name" 'any(.assets[]; .name == $n)' "$release" > /dev/null; then
    continue
  fi
  jq -e '.isDraft' "$release"
  gh api "$api/actions/runs/$run" | jq -e --arg sha "$source" --arg path ".github/workflows/$workflow" '
    .head_sha == $sha and (.head_branch == "windows-port" or .head_branch == "main") and
    .event == "push" and .path == $path and .conclusion == "success"'
  gh api "$api/actions/artifacts/$artifact" | jq -e --argjson run "$run" --arg n "$name" --arg d "sha256:$checksum" '
    .workflow_run.id == $run and .name == $n and .digest == $d and (.expired | not)'
  gh api "$api/actions/artifacts/$artifact/zip" > "$name"
  echo "$checksum  $name" | sha256sum -c -
  if [[ "$platform" == windows ]]; then
    test "$(head -c 2 "$name")" = MZ
  else
    unzip -tq "$name"
    unzip -p "$name" WordMath.app/Contents/Info.plist |
      python3 -c 'import plistlib,sys; p=plistlib.loads(sys.stdin.buffer.read()); assert p["WordMathReleaseVersion"] == sys.argv[1] and p["CFBundleShortVersionString"] == sys.argv[1].split("-")[0]' "$version"
  fi
done

# Keep the validated bytes available for upload without checking out the tagged commit again.
if ! jq -e '.databaseId' "$release" > /dev/null; then
  gh release create "$tag" --repo "$GITHUB_REPOSITORY" --draft --prerelease --target "$source" \
    --title "WordMath $version" --notes-file "$GITHUB_WORKSPACE/$notes"
fi
while read -r name; do
  if [[ -f "$name" ]]; then gh release upload "$tag" "$name" --repo "$GITHUB_REPOSITORY"; fi
done < <(jq -r '.[].name' <<< "$expected")

id=$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json databaseId --jq '.databaseId')
gh api "$api/releases/$id" | jq -e --argjson e "$expected" '
  ([.assets[] | {name,digest}] | sort_by(.name)) == ($e | sort_by(.name))'
if jq -e '.isDraft' "$release" > /dev/null; then
  gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease --latest=false
fi
while read -r name checksum; do
  curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
    "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/releases/download/$tag/$name" -o public-download
  echo "$checksum  public-download" | sha256sum -c -
done < <(jq -r '.[] | [.name, (.digest | sub("^sha256:";""))] | @tsv' <<< "$expected")
