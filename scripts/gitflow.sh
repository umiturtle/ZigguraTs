#!/usr/bin/env bash
# Validate gitflow branch names and PR bases, and configure the `git flow` tool.
#
# The repository owner owns the long-lived branches (`main`, `develop`, `feature/*`,
# `release/*`, `hotfix/*`). Arena agents work on a single `arena/*` ref per session; this script
# never creates, switches or pushes a branch, so CI can enforce the model without any agent
# needing write access to another ref.
#
#   scripts/gitflow.sh                            # classify the current branch
#   scripts/gitflow.sh --check NAME               # validate one branch name (exit 1 when invalid)
#   scripts/gitflow.sh --check-pr-base BASE HEAD  # validate a PR's base (CI runs this)
#   scripts/gitflow.sh --self-test                # run both naming tables (CI runs this)
#   scripts/gitflow.sh --init                     # write gitflow.* keys for the `git flow` tool

set -euo pipefail

is_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }
is_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; }

# Prints "<kind>|<pr-base>|<description>". The base is a recommendation, not an action.
classify() {
    local name=$1
    case "$name" in
        main)
            echo "trunk|main|the released branch; tags vX.Y.Z are cut here" ;;
        develop)
            echo "trunk|develop|integration branch for the next release" ;;
        feature/*)
            local slug=${name#feature/}
            is_slug "$slug" || return 1
            echo "feature|develop|one unit of work; merge into develop" ;;
        release/*)
            local v=${name#release/}
            is_version "$v" || return 1
            echo "release|main|version freeze; tag v$v on main, then back-merge to develop" ;;
        hotfix/*)
            local v=${name#hotfix/}
            is_version "$v" || return 1
            echo "hotfix|main|urgent fix; tag v$v on main, then back-merge to develop" ;;
        arena/*)
            local slug=${name#arena/}
            is_slug "$slug" || return 1
            echo "agent|develop|Arena session ref; branch feature/<slug>, push it, and open the PR against develop" ;;
        *)
            return 1 ;;
    esac
}

# The intake table: which head branches may open a PR against a given base. This is the rule the
# `gitflow-pr-base` CI job applies to every pull request.
pr_base_ok() {
    local base=$1 head=$2
    classify "$base" >/dev/null 2>&1 || return 1
    classify "$head" >/dev/null 2>&1 || return 1
    case "$base" in
        main)
            [[ "$head" == release/* || "$head" == hotfix/* ]] ;;
        develop)
            # `main` is the back-merge after a release; the rest is next-release work.
            [[ "$head" == main || "$head" == feature/* || "$head" == arena/* || "$head" == release/* || "$head" == hotfix/* ]] ;;
        *)
            # Stacked work: an owner branch or an agent ref may receive another non-trunk branch.
            [[ "$head" != main && "$head" != develop ]] ;;
    esac
}

print_pr_base() {
    local base=$1 head=$2
    if pr_base_ok "$base" "$head"; then
        printf 'OK PR base %s <- %s\n' "$base" "$head"
    else
        echo "INVALID PR base: $base <- $head" >&2
        echo "expected: main <- release/*|hotfix/*; develop <- main|feature/*|arena/*|release/*|hotfix/*;" >&2
        echo "          any other gitflow base <- a non-trunk branch (stacked work)" >&2
        return 1
    fi
}

self_test() {
    local ok=(
        "main" "develop"
        "feature/window-state" "feature/rpc.retry"
        "release/0.1.1" "release/1.0.0-beta.1"
        "hotfix/0.1.2"
        "arena/c1ae6863-z-ts"
    )
    local bad=(
        "feature/Uppercase" "feature/" "release/beta-1.0"
        "hotfix/v1.0" "topic/thing" "main/extra"
    )
    local name
    for name in "${ok[@]}"; do
        classify "$name" >/dev/null || { echo "FAIL: expected valid: $name" >&2; return 1; }
    done
    for name in "${bad[@]}"; do
        if classify "$name" >/dev/null 2>&1; then
            echo "FAIL: expected invalid: $name" >&2
            return 1
        fi
    done

    local ok_pairs=(
        "develop|feature/window-state" "develop|arena/c1ae6863-z-ts"
        "develop|release/0.1.1" "develop|hotfix/0.1.2" "develop|main"
        "main|release/0.1.1" "main|hotfix/0.1.2"
        "arena/a|arena/b" "feature/a|arena/b"
    )
    local bad_pairs=(
        "main|arena/c1ae6863-z-ts" "main|feature/window-state" "main|develop"
        "feature/a|main" "topic/thing|arena/a" "develop|release/beta-1.0"
    )
    local pair
    for pair in "${ok_pairs[@]}"; do
        IFS='|' read -r base head <<<"$pair"
        pr_base_ok "$base" "$head" || { echo "FAIL: expected valid PR base: $base <- $head" >&2; return 1; }
    done
    for pair in "${bad_pairs[@]}"; do
        IFS='|' read -r base head <<<"$pair"
        if pr_base_ok "$base" "$head" 2>/dev/null; then
            echo "FAIL: expected invalid PR base: $base <- $head" >&2
            return 1
        fi
    done

    echo "OK gitflow names=${#ok[@]} rejected=${#bad[@]} bases=${#ok_pairs[@]} base-rejected=${#bad_pairs[@]}"
}

# Teach the optional `git flow` tool the same branch model this script validates. Only config
# keys are written: the owner still creates every branch by hand.
init_config() {
    git config gitflow.branch.master main
    git config gitflow.branch.develop develop
    git config gitflow.prefix.feature feature/
    git config gitflow.prefix.release release/
    git config gitflow.prefix.hotfix hotfix/
    git config gitflow.prefix.support support/
    git config gitflow.prefix.versiontag v
    echo "OK gitflow config written to .git/config (compatible with the git flow tool)"
    echo "   master=main develop=develop feature/=feature/ release/=release/ hotfix/=hotfix/"
}

case "${1:-}" in
    --self-test)
        self_test ;;
    --init)
        init_config ;;
    --check)
        name=${2:?usage: gitflow.sh --check <branch-name>}
        if info=$(classify "$name"); then
            IFS='|' read -r kind base description <<<"$info"
            printf 'OK %s (%s) -> base %s — %s\n' "$name" "$kind" "$base" "$description"
        else
            echo "INVALID branch name: $name" >&2
            echo "expected: main | develop | feature/<slug> | release/<x.y.z> | hotfix/<x.y.z> | arena/<slug>" >&2
            exit 1
        fi ;;
    --check-pr-base)
        base=${2:?usage: gitflow.sh --check-pr-base <base> <head>}
        head=${3:?usage: gitflow.sh --check-pr-base <base> <head>}
        print_pr_base "$base" "$head" ;;
    "")
        current=$(git branch --show-current)
        [ -n "$current" ] || { echo "error: detached HEAD" >&2; exit 1; }
        if info=$(classify "$current"); then
            IFS='|' read -r kind base description <<<"$info"
            printf 'branch: %s (%s)\nPR base: %s\n%s\n' "$current" "$kind" "$base" "$description"
        else
            echo "INVALID branch name: $current" >&2
            exit 1
        fi ;;
    *)
        echo "usage: gitflow.sh [--check NAME] [--check-pr-base BASE HEAD] [--self-test] [--init]" >&2
        exit 2 ;;
esac
