#!/usr/bin/env bash

# Keep unstable as upstream/unstable plus one replaceable fork customization commit.
# Newly created release tags point at immutable upstream commits. Existing tags never move.
set -euo pipefail

readonly STATE_FILE='.github/upstream-sync-state.json'
readonly CONSOLIDATED_COMMIT_MESSAGE='ci: maintain daily upstream prereleases [skip ci]'
readonly -a REPLACED_PATHS=(
  '.github/workflows'
  '.github/scripts/sync-upstream.sh'
  '.github/upstream-sync-state.json'
)
readonly -a PATCHED_PATHS=(
  '.goreleaser.yml'
  'README.md'
)
readonly -a FORK_PATHS=(
  "${REPLACED_PATHS[@]}"
  "${PATCHED_PATHS[@]}"
)

fork_releases='[]'
fork_head=''
upstream_head=''
last_upstream_commit=''
last_upstream_release=''

fail() {
  echo "::error::$*" >&2
  exit 1
}

set_result() {
  local action="$1"
  local release_tag="${2:-}"
  local should_release="${3:-false}"
  local copy_upstream_metadata="${4:-false}"

  {
    echo "action=$action"
    echo "release_tag=$release_tag"
    echo "should_release=$should_release"
    echo "copy_upstream_metadata=$copy_upstream_metadata"
  } >> "$GITHUB_OUTPUT"

  {
    echo '### Upstream sync decision'
    echo "- Action: \`$action\`"
    if [[ -n "$release_tag" ]]; then
      echo "- Release tag: \`$release_tag\`"
    fi
    echo "- Fork head before run: \`${fork_head:0:12}\`"
    echo "- Recorded upstream base: \`${last_upstream_commit:0:12}\`"
    echo "- Current upstream head: \`${upstream_head:0:12}\`"
    echo "- Dry run: \`$DRY_RUN\`"
    echo "- Force rebuild: \`${FORCE_REBUILD:-false}\`"
  } >> "$GITHUB_STEP_SUMMARY"
}

has_release() {
  local tag="$1"
  jq -e --arg tag "$tag" '
    any(.[];
      .tag_name == $tag
      and (any(.assets[]?; .name == "checksums.txt"))
      and (any(.assets[]?; .name == "config.schema.json"))
      and (any(.assets[]?; .name | test("_linux_amd64\\.zip$")))
      and (any(.assets[]?; .name | test("_windows_amd64\\.zip$")))
    )
  ' <<< "$fork_releases" >/dev/null
}

has_tag() {
  git show-ref --verify --quiet "refs/tags/$1"
}

verify_tag_target() {
  local tag="$1"
  local expected_commit="$2"
  local actual_commit

  actual_commit="$(git rev-parse "refs/tags/$tag^{}")"
  if [[ "$actual_commit" != "$expected_commit" ]]; then
    fail "Existing tag '$tag' points to '$actual_commit', expected '$expected_commit'. Tags are immutable; resolve the collision manually."
  fi
}

is_fork_path() {
  case "$1" in
    .github/workflows/* | \
      .github/scripts/sync-upstream.sh | \
      .github/upstream-sync-state.json | \
      .goreleaser.yml | \
      README.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_fork_delta() {
  local base="$1"
  local source="$2"
  local path

  while IFS= read -r -d '' path; do
    if ! is_fork_path "$path"; then
      fail "Fork branch contains a non-customization change relative to '$base': $path"
    fi
  done < <(git diff --name-only -z "$base" "$source" -- .)
}

is_consolidated() {
  local -a parents
  read -r -a parents <<< "$(git rev-list --parents -n 1 "$fork_head")"
  [[ "${#parents[@]}" -eq 2 && "${parents[1]}" == "$last_upstream_commit" ]]
}

has_releasable_upstream_changes() {
  local base="$1"
  local target="$2"

  ! git diff --quiet "$base" "$target" -- \
    . \
    ':(exclude).github/workflows/**' \
    ':(exclude).github/scripts/sync-upstream.sh' \
    ':(exclude).github/upstream-sync-state.json' \
    ':(exclude).goreleaser.yml' \
    ':(exclude)README.md'
}

replace_path_from_fork() {
  local source="$1"
  local path="$2"

  git rm -r -f --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
  if git cat-file -e "${source}:${path}" 2>/dev/null; then
    git checkout "$source" -- "$path"
  fi
}

update_sync_state() {
  local commit="$1"
  local release_tag="${2:-}"
  local state_tmp

  state_tmp="$(mktemp)"
  jq --arg commit "$commit" --arg release_tag "$release_tag" '
    .last_upstream_commit = $commit
    | if $release_tag == "" then .
      else .last_upstream_release = $release_tag
      end
  ' "$STATE_FILE" > "$state_tmp"
  mv "$state_tmp" "$STATE_FILE"
}

validate_staged_customizations() {
  local path

  if git diff --cached --quiet; then
    fail 'Consolidated customization commit would be empty.'
  fi

  while IFS= read -r -d '' path; do
    if ! is_fork_path "$path"; then
      fail "Consolidated commit escaped the customization boundary: $path"
    fi
  done < <(git diff --cached --name-only -z)
}

build_consolidated_commit() {
  local base="$1"
  local release_tag="${2:-}"
  local path
  local patch_file
  local fork_author_date

  fork_author_date="$(git show -s --format=%aI "$fork_head")"
  git checkout --detach --force "$base" >/dev/null

  for path in "${REPLACED_PATHS[@]}"; do
    replace_path_from_fork "$fork_head" "$path"
  done

  patch_file="$(mktemp)"
  git diff --binary "$last_upstream_commit" "$fork_head" -- \
    "${PATCHED_PATHS[@]}" > "$patch_file"
  if [[ -s "$patch_file" ]] && ! git apply --index --3way "$patch_file"; then
    conflicted_files="$(git diff --name-only --diff-filter=U)"
    rm -f "$patch_file"
    if [[ -n "$conflicted_files" ]]; then
      printf 'Conflicting fork customization files:\n%s\n' "$conflicted_files" >&2
    fi
    fail 'Fork README or GoReleaser customization conflicts with the new upstream base.'
  fi
  rm -f "$patch_file"

  update_sync_state "$base" "$release_tag"
  git add -A -- "${FORK_PATHS[@]}"
  validate_staged_customizations
  GIT_AUTHOR_NAME="$FORK_COMMIT_AUTHOR_NAME" \
    GIT_AUTHOR_EMAIL="$FORK_COMMIT_AUTHOR_EMAIL" \
    GIT_AUTHOR_DATE="$fork_author_date" \
    git commit -m "$CONSOLIDATED_COMMIT_MESSAGE" >/dev/null
}

push_consolidated_branch() {
  local expected_head="$1"

  git push \
    --force-with-lease="refs/heads/$FORK_BRANCH:$expected_head" \
    origin "HEAD:refs/heads/$FORK_BRANCH"
}

push_consolidated_branch_and_tag() {
  local expected_head="$1"
  local tag="$2"

  git push --atomic \
    --force-with-lease="refs/heads/$FORK_BRANCH:$expected_head" \
    origin \
    "HEAD:refs/heads/$FORK_BRANCH" \
    "refs/tags/$tag:refs/tags/$tag"
}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git fetch --force --tags origin \
  "+refs/heads/$FORK_BRANCH:refs/remotes/origin/$FORK_BRANCH"
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "https://github.com/${UPSTREAM_REPOSITORY}.git"
else
  git remote add upstream "https://github.com/${UPSTREAM_REPOSITORY}.git"
fi
git fetch --force --no-tags upstream \
  "+refs/heads/$UPSTREAM_BRANCH:refs/remotes/upstream/$UPSTREAM_BRANCH"

fork_head="$(git rev-parse "refs/remotes/origin/$FORK_BRANCH")"
upstream_head="$(git rev-parse "refs/remotes/upstream/$UPSTREAM_BRANCH")"

upstream_releases="$(
  gh api --paginate --slurp \
    "repos/${UPSTREAM_REPOSITORY}/releases?per_page=100" \
    | jq -c '[add[]? | select(.draft == false)]
      | sort_by(.published_at // .created_at)'
)"
fork_releases="$(
  gh api --paginate --slurp \
    "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
    | jq -c '[add[]? | select(.draft == false)]'
)"

sync_state="$(git show "${fork_head}:${STATE_FILE}")"
last_upstream_commit="$(jq -er '.last_upstream_commit' <<< "$sync_state")"
last_upstream_release="$(jq -er '.last_upstream_release' <<< "$sync_state")"

if [[ ! "$last_upstream_commit" =~ ^[0-9a-f]{40}$ ]] || \
  ! git cat-file -e "$last_upstream_commit^{commit}"; then
  fail "Invalid upstream commit baseline: $last_upstream_commit"
fi
if ! git merge-base --is-ancestor "$last_upstream_commit" "$upstream_head"; then
  fail 'The upstream branch no longer contains the recorded commit baseline.'
fi
if [[ ! "$last_upstream_release" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-beta([0-9]+)$ ]]; then
  fail "Unsupported upstream release baseline: $last_upstream_release"
fi

version_core="${BASH_REMATCH[1]}"
beta_number="${BASH_REMATCH[2]}"
next_beta="v${version_core}-beta$((beta_number + 1))"

validate_fork_delta "$last_upstream_commit" "$fork_head"

if ! jq -e --arg tag "$last_upstream_release" \
  'any(.[]; .tag_name == $tag)' \
  <<< "$upstream_releases" >/dev/null; then
  fail "The upstream baseline release '$last_upstream_release' was not found."
fi

latest_rc_tag=''
latest_rc_number=0
while IFS= read -r tag; do
  suffix="${tag#"${next_beta}-rc"}"
  if [[ "$tag" == "${next_beta}-rc${suffix}" && "$suffix" =~ ^[0-9]+$ ]]; then
    if (( 10#$suffix > latest_rc_number )); then
      latest_rc_number=$((10#$suffix))
      latest_rc_tag="$tag"
    fi
  fi
done < <(git tag --list "${next_beta}-rc*")

# Retry an interrupted publish without moving its immutable tag.
if has_tag "$last_upstream_release" && ! has_release "$last_upstream_release"; then
  echo "Release '$last_upstream_release' is missing; retrying it."
  set_result repair "$last_upstream_release" \
    "$([[ "$DRY_RUN" == 'true' ]] && echo false || echo true)" true
  exit 0
fi
if [[ -n "$latest_rc_tag" ]] && ! has_release "$latest_rc_tag"; then
  echo "Release '$latest_rc_tag' is missing; retrying it."
  set_result repair "$latest_rc_tag" \
    "$([[ "$DRY_RUN" == 'true' ]] && echo false || echo true)" false
  exit 0
fi

pending_release="$(
  jq -c --arg last "$last_upstream_release" '
    (map(.tag_name) | index($last)) as $index
    | if $index == null then
        error("upstream baseline release is missing")
      else
        (.[($index + 1):]
          | map(select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+-beta[0-9]+$")))
          | first // empty)
      end
  ' <<< "$upstream_releases"
)"

if [[ -n "$pending_release" ]]; then
  release_tag="$(jq -r '.tag_name' <<< "$pending_release")"
  if [[ "$DRY_RUN" == 'true' ]]; then
    echo "Would mirror upstream release '$release_tag' and rebuild one fork commit."
    set_result mirror "$release_tag" false true
    exit 0
  fi

  upstream_ref="refs/upstream-sync/tags/$release_tag"
  git fetch --force --no-tags upstream \
    "refs/tags/$release_tag:$upstream_ref"
  upstream_release_commit="$(git rev-parse "$upstream_ref^{commit}")"
  if ! git merge-base --is-ancestor "$upstream_release_commit" "$upstream_head"; then
    fail "Upstream release '$release_tag' is not on '$UPSTREAM_BRANCH'."
  fi

  tag_is_new=true
  if has_tag "$release_tag"; then
    tag_is_new=false
    verify_tag_target "$release_tag" "$upstream_release_commit"
    echo "Fork tag '$release_tag' already points at the upstream release commit."
  fi

  build_consolidated_commit "$upstream_head" "$release_tag"
  if [[ "$tag_is_new" == 'true' ]]; then
    git tag "$release_tag" "$upstream_release_commit"
    push_consolidated_branch_and_tag "$fork_head" "$release_tag"
  else
    push_consolidated_branch "$fork_head"
  fi

  if has_release "$release_tag"; then
    set_result mirror "$release_tag" false true
  else
    set_result mirror "$release_tag" true true
  fi
  exit 0
fi

consolidated=false
if is_consolidated; then
  consolidated=true
fi

if [[ "$last_upstream_commit" == "$upstream_head" && \
  "$consolidated" == 'true' && "${FORCE_REBUILD:-false}" != 'true' ]]; then
  echo "Fork '$FORK_BRANCH' is current and already has one customization commit."
  set_result idle
  exit 0
fi

if [[ "$last_upstream_commit" == "$upstream_head" ]] || \
  ! has_releasable_upstream_changes "$last_upstream_commit" "$upstream_head"; then
  if [[ "$DRY_RUN" == 'true' ]]; then
    echo "Would rebuild '$FORK_BRANCH' as upstream plus one customization commit."
    set_result sync
    exit 0
  fi

  build_consolidated_commit "$upstream_head"
  push_consolidated_branch "$fork_head"
  set_result sync
  exit 0
fi

release_tag="${next_beta}-rc$((latest_rc_number + 1))"
if [[ "$DRY_RUN" == 'true' ]]; then
  echo "Would rebuild one fork commit and publish '$release_tag'."
  set_result rc "$release_tag" false false
  exit 0
fi
if has_tag "$release_tag"; then
  fail "Refusing to overwrite existing tag '$release_tag'."
fi

build_consolidated_commit "$upstream_head"
git tag "$release_tag" "$upstream_head"
push_consolidated_branch_and_tag "$fork_head" "$release_tag"
set_result rc "$release_tag" true false
