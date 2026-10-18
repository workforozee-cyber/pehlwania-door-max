#!/usr/bin/env bash
# Publishes ci-out/<job>/ (logs, test results, screenshots, APKs) to the dedicated
# branch ci-reports/<job> so results can be read with plain git. This branch only
# ever contains CI output (single commit, replaced on every run).
set +e
JOB="$1"; DIR="ci-out/$JOB"; mkdir -p "$DIR"
echo "run=$GITHUB_RUN_NUMBER sha=$GITHUB_SHA status=${JOB_STATUS:-unknown} at=$(date -u +%FT%TZ)" > "$DIR/RUN.txt"
cd "$DIR" || exit 0
git init -q && git checkout -q -b "ci-reports/$JOB"
git add -A && git -c user.name=ci-bot -c user.email=ci-bot@users.noreply.github.com commit -qm "CI report: $JOB (run $GITHUB_RUN_NUMBER)"
git push -q -f "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/ci-reports/$JOB" && echo "published ci-reports/$JOB"
exit 0
