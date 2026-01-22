#!/bin/bash
# Simply Done - Long-running AI agent loop
# Usage: ./smd.sh [prd-file.md] [max_iterations]
#        ./smd.sh                     - Shows file selector for tasks/ folder
#        ./smd.sh tasks/my-prd.md     - Uses specified PRD file
#        ./smd.sh tasks/my-prd.md 30  - Uses specified PRD with 30 max iterations

set -e

# Check dependencies
command -v jq >/dev/null 2>&1 || { echo -e "\033[0;31mError: jq is required but not installed.\033[0m"; echo "Install with: brew install jq (macOS) or apt install jq (Linux)"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo -e "\033[0;31mError: claude CLI is required but not installed.\033[0m"; echo "Install from: https://docs.anthropic.com/en/docs/claude-code"; exit 1; }

# Parse arguments
PRD_MD_FILE=""
MAX_ITERATIONS=20

if [ $# -ge 1 ]; then
  # Check if first arg is a number (max_iterations) or a file path
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS=$1
  else
    PRD_MD_FILE="$1"
    if [ $# -ge 2 ]; then
      MAX_ITERATIONS=$2
    fi
  fi
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/smd-prd.json"
PROGRESS_FILE="$SCRIPT_DIR/smd-progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
PRD_SNAPSHOT="$SCRIPT_DIR/.smd-prd-snapshot.json"
LOG_FILE="$SCRIPT_DIR/.smd-output.log"

# Cleanup on exit
trap 'stop_watcher 2>/dev/null; rm -f "$PRD_SNAPSHOT"' EXIT

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m' # No Color

TASKS_DIR="$SCRIPT_DIR/tasks"

# File selector function
select_prd_file() {
  local files=()

  # Check if tasks directory exists
  if [ ! -d "$TASKS_DIR" ]; then
    echo -e "${RED}Error: tasks/ directory not found.${NC}"
      echo "Create PRD files using '/smd-prd [description of task]' using Claude"
    exit 1
  fi

  # Find all PRD files
  while IFS= read -r file; do
    files+=("$file")
  done < <(find "$TASKS_DIR" -name "smd-prd-*.md" -type f 2>/dev/null | sort)

  if [ ${#files[@]} -eq 0 ]; then
    echo -e "${RED}Error: No PRD files found in tasks/ directory.${NC}"
    echo "Create PRD files using '/smd-prd [description of task]' using Claude"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}Select a PRD file:${NC}"
  echo ""

  local selected=0
  local key=""

  # Hide cursor
  tput civis
  trap 'tput cnorm' EXIT

  while true; do
    # Clear and redraw menu
    for i in "${!files[@]}"; do
      local filename=$(basename "${files[$i]}")
      if [ $i -eq $selected ]; then
        echo -e "\r  ${CYAN}▶${NC} ${BOLD}$filename${NC}     "
      else
        echo -e "\r    ${DIM}$filename${NC}     "
      fi
    done

    # Move cursor back up
    for ((i=0; i<${#files[@]}; i++)); do
      tput cuu1
    done

    # Read single keypress
    read -rsn1 key

    # Handle arrow keys (escape sequences)
    if [ "$key" = $'\x1b' ]; then
      read -rsn2 key
      case "$key" in
        '[A') # Up arrow
          ((selected--))
          [ $selected -lt 0 ] && selected=$((${#files[@]} - 1))
          ;;
        '[B') # Down arrow
          ((selected++))
          [ $selected -ge ${#files[@]} ] && selected=0
          ;;
      esac
    elif [ "$key" = "" ]; then
      # Enter pressed - move cursor down and break
      for ((i=0; i<${#files[@]}; i++)); do
        tput cud1
      done
      break
    fi
  done

  # Show cursor again
  tput cnorm
  trap - EXIT

  PRD_MD_FILE="${files[$selected]}"
  echo ""
  echo -e "${GREEN}Selected:${NC} $(basename "$PRD_MD_FILE")"
}

# If no PRD file specified, show selector
if [ -z "$PRD_MD_FILE" ]; then
  select_prd_file
fi

# Validate PRD markdown file exists
if [ ! -f "$PRD_MD_FILE" ]; then
  echo -e "${RED}Error: PRD file not found: $PRD_MD_FILE${NC}"
  exit 1
fi

# Check if userStories is empty and run smd-convert if needed
run_convert_if_needed() {
  local story_count=$(jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo "0")

  if [ "$story_count" = "0" ] || [ "$story_count" = "null" ]; then
    echo ""
    echo -e "${YELLOW}📋 No user stories found in smd-prd.json${NC}"
    echo -e "${DIM}Running /smd-convert to convert PRD to JSON format...${NC}"
    echo ""

    # Run claude with smd-convert skill
    claude --dangerously-skip-permissions -p "/smd-convert $PRD_MD_FILE"

    # Verify conversion succeeded
    story_count=$(jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo "0")
    if [ "$story_count" = "0" ] || [ "$story_count" = "null" ]; then
      echo -e "${RED}Error: Conversion failed. No user stories in smd-prd.json${NC}"
      exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ Converted PRD to JSON with $story_count user stories${NC}"
  fi
}

# Show all stories with their status
show_stories() {
  local description=$(jq -r '.description // "No description"' "$PRD_FILE")
  local total=$(jq '.userStories | length' "$PRD_FILE")
  local passed=$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE")

  echo ""
  echo -e "${CYAN}📋 PRD:${NC} $description"
  echo ""
  echo -e "${BOLD}Stories:${NC}"

  local next_found=false
  while IFS='|' read -r id title passes; do
    if [ "$passes" = "true" ]; then
      echo -e "  ${GREEN}✅${NC} ${DIM}$id${NC} $title"
    elif [ "$next_found" = "false" ]; then
      echo -e "  ${YELLOW}⏳${NC} ${BOLD}$id${NC} $title  ${YELLOW}← NEXT${NC}"
      next_found=true
    else
      echo -e "  ⬜ ${DIM}$id${NC} $title"
    fi
  done < <(jq -r '.userStories[] | "\(.id)|\(.title)|\(.passes)"' "$PRD_FILE")

  echo ""
  echo -e "Progress: ${GREEN}$passed${NC}/${total} complete"
}

# Get next incomplete story
get_next_story() {
  jq -r '.userStories[] | select(.passes == false) | "\(.id)|\(.title)"' "$PRD_FILE" | head -1
}

# Get story counts
get_story_counts() {
  local total=$(jq '.userStories | length' "$PRD_FILE")
  local passed=$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE")
  echo "$passed|$total"
}

# Save snapshot before iteration
save_snapshot() {
  cp "$PRD_FILE" "$PRD_SNAPSHOT"
}

# Background watcher - monitors smd-prd.json for task completions
start_watcher() {
  (
    # Track what we've already announced (prevents re-announcing on file read races)
    announced_completed=""
    announced_started=""

    # Initialize with current completed stories
    initial_passed=$(jq -r '.userStories[] | select(.passes == true) | .id' "$PRD_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [ -n "$initial_passed" ]; then
      announced_completed="$initial_passed"
    fi

    while true; do
      sleep 2

      # Get current state from smd-prd.json
      now_passed=$(jq -r '.userStories[] | select(.passes == true) | .id' "$PRD_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      now_next=$(jq -r '.userStories[] | select(.passes == false) | .id' "$PRD_FILE" 2>/dev/null | head -1)

      # Skip if jq returned empty (likely file being written)
      [ -z "$now_passed" ] && [ -z "$now_next" ] && continue

      # Announce newly completed tasks (only once ever)
      for id in $(echo "$now_passed" | tr ',' '\n'); do
        if [ -n "$id" ] && ! echo ",$announced_completed," | grep -q ",$id,"; then
          title=$(jq -r --arg id "$id" '.userStories[] | select(.id == $id) | .title' "$PRD_FILE" 2>/dev/null)
          [ -n "$title" ] && echo -e "   ${GREEN}✓${NC} ${BOLD}$id${NC} completed - $title"
          announced_completed="$announced_completed,$id"
        fi
      done

      # Announce new task starting (only if not already completed or announced)
      if [ -n "$now_next" ] && [ "$now_next" != "$announced_started" ]; then
        # Don't announce starting a task that's already completed
        if ! echo ",$announced_completed," | grep -q ",$now_next,"; then
          title=$(jq -r --arg id "$now_next" '.userStories[] | select(.id == $id) | .title' "$PRD_FILE" 2>/dev/null)
          [ -n "$title" ] && echo -e "   ${YELLOW}→${NC} Starting ${BOLD}$now_next${NC} - $title"
          announced_started="$now_next"
        fi
      fi
    done
  ) &
  WATCHER_PID=$!
}

# Stop the background watcher
stop_watcher() {
  if [ -n "$WATCHER_PID" ]; then
    kill $WATCHER_PID 2>/dev/null || true
    wait $WATCHER_PID 2>/dev/null || true
  fi
}

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "smd/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^smd/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    # Reset progress file for new run
    echo "# Simply Done Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Simply Done Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

# Validate PRD file exists and has content
if [ ! -f "$PRD_FILE" ]; then
  echo -e "${RED}Error: PRD file not found at $PRD_FILE${NC}"
  echo "Run /smd-prd first to generate the PRD file."
  exit 1
fi

# Auto-convert PRD if userStories is empty
run_convert_if_needed

# Validate branch configuration
PRD_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

if [ -z "$PRD_BRANCH" ]; then
  echo -e "${YELLOW}Warning: No branchName specified in PRD file.${NC}"
  echo -e "${DIM}Changes will be made on current branch: $GIT_BRANCH${NC}"
  echo ""
elif [ "$PRD_BRANCH" != "$GIT_BRANCH" ]; then
  echo -e "${YELLOW}Warning: Current branch ($GIT_BRANCH) doesn't match PRD branch ($PRD_BRANCH)${NC}"
  read -p "Switch to $PRD_BRANCH? (y/n) " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if git show-ref --verify --quiet refs/heads/"$PRD_BRANCH"; then
      git checkout "$PRD_BRANCH"
    else
      git checkout -b "$PRD_BRANCH"
    fi
  else
    echo -e "${DIM}Continuing on current branch: $GIT_BRANCH${NC}"
  fi
fi

echo ""
echo -e "${BOLD}✅ Starting Simply Done${NC} - Max iterations: $MAX_ITERATIONS"

# Show initial state
show_stories

for i in $(seq 1 $MAX_ITERATIONS); do
  # Get current task info
  NEXT_STORY=$(get_next_story)
  STORY_ID=$(echo "$NEXT_STORY" | cut -d'|' -f1)
  STORY_TITLE=$(echo "$NEXT_STORY" | cut -d'|' -f2)
  COUNTS=$(get_story_counts)
  PASSED=$(echo "$COUNTS" | cut -d'|' -f1)
  TOTAL=$(echo "$COUNTS" | cut -d'|' -f2)

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "  ${BOLD}Iteration $i of $MAX_ITERATIONS${NC} │ Progress: ${GREEN}$PASSED${NC}/$TOTAL"
  if [ -n "$STORY_ID" ]; then
    echo -e "  ${YELLOW}Working on:${NC} ${BOLD}$STORY_ID${NC}"
    echo -e "  $STORY_TITLE"
  fi
  echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
  echo ""

  # Save snapshot for change detection
  save_snapshot

  # Show start time
  START_TIME=$(date +%s)
  echo -e "${DIM}Started at $(date '+%H:%M:%S')${NC}"
  echo ""

  # Start background watcher for real-time task updates
  start_watcher

  # Run claude with the prompt - stream to both terminal and log file
  echo -e "   ${DIM}Running Claude...${NC}"
  echo ""
  # Stream JSON and filter to show tool calls in real-time
  claude --dangerously-skip-permissions --verbose --output-format stream-json -p "$(cat "$SCRIPT_DIR/smd-prompt.md")" 2>&1 | tee "$LOG_FILE" | while IFS= read -r line; do
    # Extract tool names and context from JSON stream
    tool_info=$(echo "$line" | jq -r '
      select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") |
      .name as $name | .input as $input |
      if $name == "Read" then "\($name) \($input.file_path // "" | split("/") | .[-1])"
      elif $name == "Write" then "\($name) \($input.file_path // "" | split("/") | .[-1])"
      elif $name == "Edit" then "\($name) \($input.file_path // "" | split("/") | .[-1])"
      elif $name == "Bash" then "\($name) \($input.command // "" | .[0:80])"
      elif $name == "Glob" then "\($name) \($input.pattern // "")"
      elif $name == "Grep" then "\($name) \($input.pattern // "" | .[0:50])"
      elif $name == "TodoWrite" then "\($name) \($input.todos[]? | select(.status == "in_progress") | .activeForm // "" | .[0:60])"
      else "\($name) \($input | tostring | .[0:60])"
      end
    ' 2>/dev/null)
    if [ -n "$tool_info" ] && [ "$tool_info" != "null" ]; then
      echo -e "   ${DIM}→ $tool_info${NC}"
    fi
  done || true
  OUTPUT=$(cat "$LOG_FILE")

  # Stop the watcher
  stop_watcher

  # Calculate elapsed time
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))
  MINS=$((ELAPSED / 60))
  SECS=$((ELAPSED % 60))

  echo ""
  echo -e "${DIM}───────────────────────────────────────────────────────────────${NC}"

  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo -e "${GREEN}🎉 All tasks completed!${NC}"
    echo -e "${DIM}Finished at iteration $i of $MAX_ITERATIONS (${MINS}m ${SECS}s)${NC}"
    echo -e "${DIM}Full log: $LOG_FILE${NC}"
    rm -f "$PRD_SNAPSHOT"
    exit 0
  fi

  # Show updated progress
  COUNTS=$(get_story_counts)
  PASSED=$(echo "$COUNTS" | cut -d'|' -f1)
  NEXT_STORY=$(get_next_story)
  NEXT_ID=$(echo "$NEXT_STORY" | cut -d'|' -f1)

  echo -e "   ${DIM}Iteration completed in ${MINS}m ${SECS}s${NC}"
  echo -e "   Progress: ${GREEN}$PASSED${NC}/$TOTAL stories done"
  if [ -n "$NEXT_ID" ]; then
    echo -e "   ${DIM}Next up: $NEXT_ID${NC}"
  fi
  echo ""

  # Check if a story was completed - if so, start fresh session for next story
  PREV_PASSED=$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_SNAPSHOT" 2>/dev/null || echo "0")
  if [ "$PASSED" -gt "$PREV_PASSED" ]; then
    echo -e "   ${GREEN}Story completed - starting fresh session for next story${NC}"
    sleep 1
    continue
  fi

  sleep 1
done

echo ""
echo -e "${RED}⚠️  Reached max iterations ($MAX_ITERATIONS) without completing all tasks.${NC}"
echo -e "${DIM}Progress: $PROGRESS_FILE${NC}"
echo -e "${DIM}Full log: $LOG_FILE${NC}"
rm -f "$PRD_SNAPSHOT"
exit 1
