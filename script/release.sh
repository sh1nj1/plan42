#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_DIR="$PROJECT_ROOT/build/gems"
ENGINES_DIR="$PROJECT_ROOT/engines"
RELEASE_BRANCH="release/$(date +%Y%m%d-%H%M%S)"

# Discover engines dynamically (directories with .gemspec files)
ENGINES=()
for gemspec in "$ENGINES_DIR"/*/*.gemspec; do
  if [ -f "$gemspec" ]; then
    ENGINE_NAME=$(basename "$(dirname "$gemspec")")
    ENGINES+=("$ENGINE_NAME")
  fi
done

if [ ${#ENGINES[@]} -eq 0 ]; then
  echo -e "${RED}Error: No engines found in $ENGINES_DIR${NC}"
  exit 1
fi

echo -e "${BLUE}Discovered engines:${NC} ${ENGINES[*]}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Collavre Engines Release Script${NC}"
echo -e "${BLUE}========================================${NC}"

# Check we're on main
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo -e "${RED}Error: Must be on main branch (currently on: $CURRENT_BRANCH)${NC}"
  exit 1
fi

# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
  echo -e "${RED}Error: Uncommitted changes exist. Please commit or stash first.${NC}"
  exit 1
fi

# Pull latest
echo -e "${YELLOW}Pulling latest from main...${NC}"
git pull origin main

# Step 0: Create release branch
echo -e "\n${GREEN}[Step 0] Creating release branch: $RELEASE_BRANCH${NC}"
git checkout -b "$RELEASE_BRANCH"

# Step 1: Run tests
echo -e "\n${GREEN}[Step 1] Running tests...${NC}"
echo -e "${YELLOW}Running npm test...${NC}"
npm test

echo -e "${YELLOW}Running rake test...${NC}"
bundle exec rake test

echo -e "${YELLOW}Running rake test:system...${NC}"
bundle exec rake test:system

echo -e "${GREEN}All tests passed!${NC}"

# Step 2: Determine versions and generate release notes
echo -e "\n${GREEN}[Step 2] Analyzing changes and determining versions...${NC}"

declare -A ENGINE_NEW_VERSIONS
declare -A ENGINE_HAS_CHANGES

for ENGINE in "${ENGINES[@]}"; do
  ENGINE_DIR="$ENGINES_DIR/$ENGINE"
  VERSION_FILE="$ENGINE_DIR/lib/${ENGINE}/version.rb"
  
  # Get current version
  CURRENT_VERSION=$(grep -oP 'VERSION\s*=\s*"\K[^"]+' "$VERSION_FILE")
  
  # Get last commit that modified version.rb
  LAST_VERSION_COMMIT=$(git log -1 --format="%H" -- "$VERSION_FILE" 2>/dev/null || echo "")
  
  # Get commits in engine dir since last version change
  if [ -n "$LAST_VERSION_COMMIT" ]; then
    COMMITS=$(git log --oneline "$LAST_VERSION_COMMIT..HEAD" -- "$ENGINE_DIR" 2>/dev/null | grep -v "^$" || true)
  else
    COMMITS=$(git log --oneline -- "$ENGINE_DIR" 2>/dev/null | head -20 || true)
  fi
  
  if [ -n "$COMMITS" ]; then
    ENGINE_HAS_CHANGES[$ENGINE]=1
    
    # Bump patch version
    IFS='.' read -ra VERSION_PARTS <<< "$CURRENT_VERSION"
    MAJOR=${VERSION_PARTS[0]}
    MINOR=${VERSION_PARTS[1]}
    PATCH=${VERSION_PARTS[2]}
    NEW_PATCH=$((PATCH + 1))
    NEW_VERSION="$MAJOR.$MINOR.$NEW_PATCH"
    ENGINE_NEW_VERSIONS[$ENGINE]=$NEW_VERSION
    
    echo -e "${BLUE}$ENGINE:${NC} $CURRENT_VERSION -> ${GREEN}$NEW_VERSION${NC}"
    echo "  Changes since last release:"
    echo "$COMMITS" | while read -r line; do echo "    - $line"; done
    
    # Generate release notes
    RELEASE_NOTE_FILE="$ENGINE_DIR/RELEASE_NOTES.md"
    RELEASE_DATE=$(date +%Y-%m-%d)
    
    # Create or update release notes
    if [ -f "$RELEASE_NOTE_FILE" ]; then
      EXISTING_CONTENT=$(cat "$RELEASE_NOTE_FILE")
    else
      EXISTING_CONTENT=""
    fi
    
    NEW_RELEASE_CONTENT="## v$NEW_VERSION ($RELEASE_DATE)

### Changes
$(echo "$COMMITS" | while read -r line; do echo "- $line"; done)

"
    
    echo -e "$NEW_RELEASE_CONTENT$EXISTING_CONTENT" > "$RELEASE_NOTE_FILE"
    
    # Update version.rb
    if [[ "$ENGINE" == "collavre" ]]; then
      MODULE_NAME="Collavre"
    else
      # Convert collavre_slack -> CollavreSlack
      MODULE_NAME=$(echo "$ENGINE" | sed -r 's/(^|_)([a-z])/\U\2/g')
    fi
    
    cat > "$VERSION_FILE" << EOF
module $MODULE_NAME
  VERSION = "$NEW_VERSION"
end
EOF
    
  else
    ENGINE_HAS_CHANGES[$ENGINE]=0
    echo -e "${YELLOW}$ENGINE:${NC} No changes since last release (staying at $CURRENT_VERSION)"
  fi
done

# Step 3: Commit version changes
echo -e "\n${GREEN}[Step 3] Committing version updates...${NC}"

CHANGED_ENGINES=""
for ENGINE in "${ENGINES[@]}"; do
  if [ "${ENGINE_HAS_CHANGES[$ENGINE]}" == "1" ]; then
    CHANGED_ENGINES="$CHANGED_ENGINES $ENGINE@${ENGINE_NEW_VERSIONS[$ENGINE]}"
  fi
done

if [ -n "$CHANGED_ENGINES" ]; then
  git add -A
  git commit -m "chore(release): bump versions -$CHANGED_ENGINES"
  echo -e "${GREEN}Committed version updates${NC}"
else
  echo -e "${YELLOW}No engines have changes to release${NC}"
fi

# Step 4: Build gems
echo -e "\n${GREEN}[Step 4] Building gems...${NC}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

for ENGINE in "${ENGINES[@]}"; do
  if [ "${ENGINE_HAS_CHANGES[$ENGINE]}" == "1" ]; then
    ENGINE_DIR="$ENGINES_DIR/$ENGINE"
    echo -e "${BLUE}Building $ENGINE...${NC}"
    
    cd "$ENGINE_DIR"
    gem build "${ENGINE}.gemspec"
    mv *.gem "$BUILD_DIR/"
    cd "$PROJECT_ROOT"
    
    echo -e "${GREEN}  Built: ${ENGINE}-${ENGINE_NEW_VERSIONS[$ENGINE]}.gem${NC}"
  fi
done

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}  Release preparation complete!${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${YELLOW}Built gems:${NC}"
ls -la "$BUILD_DIR"/*.gem 2>/dev/null || echo "  (no gems built)"

echo -e "\n${YELLOW}Next steps:${NC}"
echo "  1. Review the changes:"
echo "     git log --oneline main..$RELEASE_BRANCH"
echo ""
echo "  2. Push all gems:"
echo "     for gem in $BUILD_DIR/*.gem; do gem push \"\$gem\"; done"
echo ""
echo "  3. Merge release branch to main and push:"
echo "     git checkout main"
echo "     git merge $RELEASE_BRANCH"
echo "     git push origin main"
echo "     git branch -d $RELEASE_BRANCH"
echo ""
echo "  4. Create git tags (optional):"
for ENGINE in "${ENGINES[@]}"; do
  if [ "${ENGINE_HAS_CHANGES[$ENGINE]}" == "1" ]; then
    echo "     git tag ${ENGINE}-v${ENGINE_NEW_VERSIONS[$ENGINE]}"
  fi
done
echo "     git push origin --tags"
