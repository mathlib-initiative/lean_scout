#!/usr/bin/env bash
set -euo pipefail

before_sha="${BEFORE_SHA:?BEFORE_SHA must be set}"
after_sha="$(git rev-parse HEAD)"

if [[ "$after_sha" == "$before_sha" ]]; then
  echo "lean-update did not create a new commit; skipping tag."
  exit 0
fi

if git diff --quiet "$before_sha" "$after_sha" -- lean-toolchain; then
  echo "lean-toolchain did not change; skipping tag."
  exit 0
fi

toolchain="$(tr -d '\r\n' < lean-toolchain)"
case "$toolchain" in
  leanprover/lean4:*)
    tag="${toolchain#leanprover/lean4:}"
    ;;
  *)
    echo "Unexpected lean-toolchain contents: $toolchain" >&2
    exit 1
    ;;
esac

echo "Candidate tag: $tag"
echo "Target commit: $after_sha"

if git ls-remote --exit-code --tags --refs origin "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists; nothing to do."
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git tag -a "$tag" -m "$tag" "$after_sha"

if git push origin "refs/tags/$tag"; then
  echo "Created tag $tag"
  exit 0
fi

echo "Initial push failed; checking whether tag was created concurrently..."
git fetch --force --tags origin

if git ls-remote --exit-code --tags --refs origin "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag now exists; treating as success."
  exit 0
fi

echo "Failed to create tag $tag" >&2
exit 1
