#!/usr/bin/env bash
# Point git at the repo's tracked hooks so the migration guard runs on commit.
# Run once after cloning:  scripts/install-hooks.sh
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
chmod +x "$repo_root/scripts/git-hooks/pre-commit"
git -C "$repo_root" config core.hooksPath scripts/git-hooks
echo "✓ core.hooksPath → scripts/git-hooks (migration guard runs on every commit)"
