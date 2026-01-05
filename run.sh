#!/usr/bin/env bash
set -euo pipefail

# ── Directory of this script (repo root assumed) ───────────────────────────────
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# ── Git update on boot (safe-ish) ─────────────────────────────────────────────
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Si sunt mutationes locales, non trahimus (ne rem frangamus).
  if git diff --quiet && git diff --cached --quiet; then
    # Discimus quid sit ramus currentis (main/master/etc).
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    git fetch --quiet origin || true

    # Tantum fast-forward, nulla merge-committa.
    if git rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
      if ! git merge-base --is-ancestor HEAD "origin/$BRANCH"; then
        echo "[run] local branch has diverged; skipping pull"
      else
        if git rev-parse HEAD >/dev/null 2>&1; then
          if git rev-parse HEAD | grep -q .; then :; fi
        fi
        if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
          echo "[run] update available → pulling (ff-only)"
          git pull --ff-only --quiet origin "$BRANCH" || echo "[run] pull failed; continuing"
        else
          echo "[run] up-to-date"
        fi
      fi
    else
      echo "[run] no origin/$BRANCH found; skipping pull"
    fi
  else
    echo "[run] local changes detected; skipping git pull"
  fi
else
  echo "[run] git not available or not a repo; skipping update"
fi

# ── Start services ────────────────────────────────────────────────────────────
python3 webcontrol.py &

# Foreground main app. (Hoc 'exec' bene est: reponit shell).
exec python3 kioskplayer.py
