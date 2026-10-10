#!/usr/bin/env bash
# LocalMind -> GitHub -> Codespaces, in one shot.
#
# Usage:  bash setup_github.sh [repo-name]
# Default repo name: localmind
#
# What it does:
#   1. Checks GitHub CLI auth (prompts you to log in once if needed)
#   2. Creates the repository on your account
#   3. Pushes this project to it
#   4. Prints a one-click URL to open the Codespace
#
# Nothing is sent anywhere except to your own GitHub account.
set -euo pipefail

REPO_NAME="${1:-localmind}"

echo "================================================"
echo " LocalMind -> GitHub setup"
echo "================================================"
echo ""

# ---------------------------------------------------------------- 1. auth
if ! gh auth status >/dev/null 2>&1; then
  echo "==> You are not logged into GitHub yet."
  echo ""
  echo "    Run the login now. Choose:"
  echo "      • GitHub.com"
  echo "      • HTTPS"
  echo "      • Authenticate with a browser  (or paste a token when prompted)"
  echo ""
  echo "    A one-time code will be shown - enter it at the URL it prints."
  echo ""
  read -r -p "    Press Enter to start 'gh auth login'..."
  gh auth login
  echo ""
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: Still not authenticated. Re-run this script after logging in."
  exit 1
fi

GH_USER="$(gh api user --jq .login)"
echo "==> Authenticated as: $GH_USER"

# ---------------------------------------------------------------- 2. repo
cd "$(dirname "$0")"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "==> Initializing git repository"
  git init -q
  git add -A
  git -c user.email="${GH_USER}@users.noreply.github.com" \
      -c user.name="$GH_USER" \
      commit -q -m "LocalMind: fully local privacy-first AI agent for Android"
fi

if gh repo view "$GH_USER/$REPO_NAME" >/dev/null 2>&1; then
  echo "==> Repository $GH_USER/$REPO_NAME already exists - pushing to it"
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$GH_USER/$REPO_NAME.git"
  git branch -M main
  git push -u origin main
else
  echo "==> Creating repository $GH_USER/$REPO_NAME (public)"
  git branch -M main
  gh repo create "$REPO_NAME" \
    --public \
    --source=. \
    --remote=origin \
    --push \
    --description "Fully local, privacy-first AI agent for Android (Flutter + llama.cpp)"
fi

echo ""
echo "==> Done. Repository: https://github.com/$GH_USER/$REPO_NAME"

# ---------------------------------------------------------------- 4. codespace
echo ""
echo "================================================"
echo " OPEN YOUR CODESPACE (one click):"
echo ""
echo "   https://codespaces.new/$GH_USER/$REPO_NAME"
echo ""
echo " First boot takes ~5 minutes: it auto-installs"
echo " Flutter 3.24 + Android SDK 34."
echo ""
echo " Then in the Codespace terminal run:"
echo ""
echo "   flutter pub get"
echo "   flutter build apk --release"
echo ""
echo " APK -> build/app/outputs/flutter-apk/app-release.apk"
echo " Right-click it in the Explorer panel -> Download"
echo "================================================"
