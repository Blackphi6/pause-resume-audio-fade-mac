#!/bin/bash
# GitHub 上の配布状況を表示する。使い方: ./scripts/stats.sh
# 前提: gh にログイン済み。アクセス解析（clones/views）はリポジトリの管理者権限が必要。
set -euo pipefail

REPO="Blackphi6/pause-resume-audio-fade-mac"

echo "== リリースごとのダウンロード数（累計・新しい順）=="
gh api "repos/$REPO/releases" --paginate \
    --jq '.[] | "\(.tag_name)\t\([.assets[].download_count] | add // 0)"' \
    | tee /tmp/prafm_downloads.tsv | column -t -s $'\t'
awk -F'\t' '{ total += $2 } END { printf "合計\t%d\n", total }' /tmp/prafm_downloads.tsv | column -t -s $'\t'
rm -f /tmp/prafm_downloads.tsv

echo
echo "== 直近14日のアクセス（GitHub は14日分しか保持しません）=="
gh api "repos/$REPO/traffic/clones" --jq '"clone      \(.count) 回 / \(.uniques) 人"'
gh api "repos/$REPO/traffic/views" --jq '"ページ閲覧  \(.count) 回 / \(.uniques) 人"'
gh api "repos/$REPO/traffic/popular/referrers" \
    --jq '.[] | "流入元      \(.referrer): \(.count) 回 / \(.uniques) 人"'
