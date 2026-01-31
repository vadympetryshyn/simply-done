#!/bin/zsh
# Simply Done - Long-running AI agent loop
# Note: Uses zsh for associative array support (bash 3.2 on macOS doesn't support -A)
# Usage: .smd/smd.sh [prd-file.md] [max_iterations]
#        .smd/smd.sh                        - Shows file selector for .smd/tasks/ folder
#        .smd/smd.sh tasks/my-prd.md        - Uses specified PRD file (relative to .smd/)
#        .smd/smd.sh tasks/my-prd.md 30     - Uses specified PRD with 30 max iterations

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
# Script is located in .smd directory
SMD_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve PRD_MD_FILE relative to SMD_DIR if not absolute
if [ -n "$PRD_MD_FILE" ]; then
  if [[ "$PRD_MD_FILE" = /* ]]; then
    :  # Already absolute, do nothing
  else
    PRD_MD_FILE="$SMD_DIR/$PRD_MD_FILE"
  fi
fi

PRD_FILE="$SMD_DIR/smd-prd.json"
PROGRESS_FILE="$SMD_DIR/smd-progress.txt"
ARCHIVE_DIR="$SMD_DIR/archive"
LAST_BRANCH_FILE="$SMD_DIR/.last-branch"
PRD_SNAPSHOT="$SMD_DIR/.smd-prd-snapshot.json"
LOG_FILE="$SMD_DIR/.smd-output.log"

# Graceful shutdown for parallel execution
cleanup_parallel() {
  echo ""
  echo -e "${YELLOW}Shutting down workers...${NC}"

  # Kill all worker processes
  for wid in ${(k)WORKER_PIDS}; do
    local pid="${WORKER_PIDS[$wid]}"
    local story_id="${WORKER_STORIES[$wid]}"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      echo -e "   Stopped Worker $wid ($story_id)"
    fi
    # Clean up done files
    rm -f "$SMD_DIR/.smd-worker-${wid}.done"
  done

  # Stop watcher
  stop_watcher 2>/dev/null || true

  # Reset in_progress stories to pending for next run
  if [ -f "$PRD_FILE" ]; then
    local tmp_file=$(mktemp)
    jq '.userStories |= map(if .status == "in_progress" then .status = "pending" else . end)' "$PRD_FILE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$PRD_FILE"
  fi

  rm -f "$PRD_SNAPSHOT"
  echo -e "${DIM}Workers stopped. Run smd.sh again to resume.${NC}"
}

# Cleanup on exit
trap 'cleanup_parallel' EXIT
trap 'cleanup_parallel; exit 130' INT TERM

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Parallel execution settings
MAX_PARALLEL_WORKERS=5
declare -A WORKER_PIDS        # Maps worker_id -> PID
declare -A WORKER_STORIES     # Maps worker_id -> story_id
declare -A WORKER_LOGS        # Maps worker_id -> log_file_path
declare -A WORKER_START_TIMES # Maps worker_id -> start timestamp

TASKS_DIR="$SMD_DIR/tasks"

# File selector function
select_prd_file() {
  local files=()

  # Check if tasks directory exists
  if [ ! -d "$TASKS_DIR" ]; then
    echo -e "${RED}Error: .smd/tasks/ directory not found.${NC}"
    echo "Create PRD files using '/smd-prd [description of task]' using Claude"
    exit 1
  fi

  # Find all PRD files
  while IFS= read -r file; do
    files+=("$file")
  done < <(find "$TASKS_DIR" -name "smd-prd-*.md" -type f 2>/dev/null | sort)

  if [ ${#files[@]} -eq 0 ]; then
    echo -e "${RED}Error: No PRD files found in .smd/tasks/ directory.${NC}"
    echo "Create PRD files using '/smd-prd [description of task]' using Claude"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}Select a PRD file:${NC}"
  echo ""

  local selected=1  # zsh arrays are 1-indexed
  local key=""
  local file_count=${#files[@]}

  # Hide cursor
  tput civis
  trap 'tput cnorm' EXIT

  while true; do
    # Clear and redraw menu
    for ((i=1; i<=file_count; i++)); do
      local filename=$(basename "${files[$i]}")
      if [ $i -eq $selected ]; then
        echo -e "\r  ${CYAN}▶${NC} ${BOLD}$filename${NC}     "
      else
        echo -e "\r    ${DIM}$filename${NC}     "
      fi
    done

    # Move cursor back up
    for ((i=1; i<=file_count; i++)); do
      tput cuu1
    done

    # Read single keypress (zsh syntax)
    read -rsk1 key

    # Handle arrow keys (escape sequences)
    if [ "$key" = $'\x1b' ]; then
      read -rsk2 key
      case "$key" in
        '[A') # Up arrow
          selected=$((selected - 1))
          [ $selected -lt 1 ] && selected=$file_count
          ;;
        '[B') # Down arrow
          selected=$((selected + 1))
          [ $selected -gt $file_count ] && selected=1
          ;;
      esac
    elif [[ "$key" == $'\n' ]] || [[ "$key" == $'\r' ]] || [[ -z "$key" ]]; then
      # Enter pressed - move cursor down and break
      for ((i=1; i<=file_count; i++)); do
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
    echo -e "${YELLOW}📋 No user stories found in .smd/smd-prd.json${NC}"
    echo -e "${DIM}Running /smd-convert to convert PRD to JSON format...${NC}"
    echo ""

    # Run claude with smd-convert skill
    claude --dangerously-skip-permissions -p "/smd-convert $PRD_MD_FILE"

    # Verify conversion succeeded
    story_count=$(jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo "0")
    if [ "$story_count" = "0" ] || [ "$story_count" = "null" ]; then
      echo -e "${RED}Error: Conversion failed. No user stories in .smd/smd-prd.json${NC}"
      exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ Converted PRD to JSON with $story_count user stories${NC}"
  fi
}

# Show all stories with their status (legacy sequential mode)
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

# Show all stories with parallel execution status
show_parallel_status() {
  local description=$(jq -r '.description // "No description"' "$PRD_FILE")
  local total=$(jq '.userStories | length' "$PRD_FILE")
  local passed=$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE")

  echo ""
  echo -e "${CYAN}📋 PRD:${NC} $description"
  echo ""

  # Display header
  printf "  %-8s %-6s %-50s %s\n" "ID" "Status" "Title" "Worker"
  echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────${NC}"

  while IFS='|' read -r id title story_status passes; do
    local status_icon=""
    local worker_info=""

    # Handle null/missing status by deriving from passes
    if [ "$story_status" = "null" ] || [ -z "$story_status" ]; then
      if [ "$passes" = "true" ]; then
        story_status="completed"
      else
        story_status="pending"
      fi
    fi

    case "$story_status" in
      "completed")
        status_icon="${GREEN}✅${NC}"
        ;;
      "in_progress")
        status_icon="${YELLOW}⏳${NC}"
        # Find which worker is running this story
        for wid in ${(k)WORKER_STORIES}; do
          if [ "${WORKER_STORIES[$wid]}" = "$id" ]; then
            worker_info="${CYAN}[W$wid]${NC}"
            break
          fi
        done
        ;;
      "failed")
        status_icon="${RED}✗${NC}"
        ;;
      *)
        status_icon="⬜"
        ;;
    esac

    # Truncate title if too long
    if [ ${#title} -gt 48 ]; then
      title="${title:0:45}..."
    fi

    printf "  %-8s %b %-50s %b\n" "$id" "$status_icon" "$title" "$worker_info"

  done < <(jq -r '.userStories[] | "\(.id)|\(.title)|\(.status)|\(.passes)"' "$PRD_FILE")

  echo ""
  echo -e "  Progress: ${GREEN}$passed${NC}/${total} complete"
}

# Show real-time worker status line (used during polling)
show_worker_status_line() {
  local status_parts=()

  for wid in ${(k)WORKER_STORIES}; do
    local story_id="${WORKER_STORIES[$wid]}"
    local start_time="${WORKER_START_TIMES[$wid]}"
    local elapsed=$(($(date +%s) - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    status_parts+=("W$wid:$story_id(${mins}m${secs}s)")
  done

  if [ ${#status_parts[@]} -gt 0 ]; then
    # Use carriage return to overwrite line
    printf "\r   ${YELLOW}⏳${NC} Running: %s     " "${status_parts[*]}"
  fi
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

# Get stories that are ready to run (all dependencies completed, status=pending)
get_ready_stories() {
  jq -r '
    .userStories as $all |
    .userStories[] |
    select((.status == "pending") or (.status == null and (.passes | not))) |
    select(
      (.dependencies // []) as $deps |
      ($deps | length == 0) or
      ($deps | all(. as $dep | $all[] | select(.id == $dep) | (.status == "completed") or (.passes == true)))
    ) |
    .id
  ' "$PRD_FILE" 2>/dev/null
}

# Update a story's status field
update_story_status() {
  local story_id="$1"
  local new_status="$2"  # pending, in_progress, completed, failed

  local tmp_file=$(mktemp)
  jq --arg id "$story_id" --arg status "$new_status" '
    .userStories |= map(if .id == $id then .status = $status else . end)
  ' "$PRD_FILE" > "$tmp_file" && mv "$tmp_file" "$PRD_FILE"
}

# Get story title by ID
get_story_title() {
  local story_id="$1"
  jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .title' "$PRD_FILE" 2>/dev/null
}

# Start a Claude worker for a specific story
start_worker() {
  local worker_id="$1"
  local story_id="$2"
  local story_title="$3"

  local worker_log="$SMD_DIR/.smd-worker-${worker_id}.log"
  local worker_done="$SMD_DIR/.smd-worker-${worker_id}.done"

  # Remove any stale done file
  rm -f "$worker_done"

  # Update story status to in_progress
  update_story_status "$story_id" "in_progress"

  # Start Claude in background with story-specific focus
  (
    # Add story focus to the prompt
    local full_prompt="$(cat "$SMD_DIR/smd-prompt.md")

## PARALLEL EXECUTION - WORKER $worker_id

You are Worker $worker_id running in parallel mode. Focus ONLY on this story:
- **Story ID**: $story_id
- **Title**: $story_title

Other stories may be running in parallel. Be careful:
1. Only modify files directly related to YOUR story
2. Update only YOUR story's \`passes\` and \`status\` fields in smd-prd.json
3. Check file modification times before editing if unsure
"

    echo "$full_prompt" | claude --dangerously-skip-permissions --verbose --output-format stream-json -p "$(cat)" > "$worker_log" 2>&1

    # Signal completion by touching a done file
    touch "$worker_done"
  ) &

  local pid=$!
  WORKER_PIDS[$worker_id]=$pid
  WORKER_STORIES[$worker_id]=$story_id
  WORKER_LOGS[$worker_id]=$worker_log
  WORKER_START_TIMES[$worker_id]=$(date +%s)
}

# Check if a worker has completed
check_worker_done() {
  local worker_id="$1"
  local done_file="$SMD_DIR/.smd-worker-${worker_id}.done"

  if [ -f "$done_file" ]; then
    return 0  # Done
  fi

  # Also check if process is still running
  local pid="${WORKER_PIDS[$worker_id]}"
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    return 0  # Process ended
  fi

  return 1  # Still running
}

# Process worker completion - check results and update status
process_worker_completion() {
  local worker_id="$1"
  local story_id="${WORKER_STORIES[$worker_id]}"
  local log_file="${WORKER_LOGS[$worker_id]}"
  local start_time="${WORKER_START_TIMES[$worker_id]}"
  local end_time=$(date +%s)
  local elapsed=$((end_time - start_time))
  local mins=$((elapsed / 60))
  local secs=$((elapsed % 60))
  local done_file="$SMD_DIR/.smd-worker-${worker_id}.done"

  # Clean up done file
  rm -f "$done_file"

  # Check if story was marked as passed in PRD
  local passes=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .passes' "$PRD_FILE" 2>/dev/null)
  local title=$(get_story_title "$story_id")

  if [ "$passes" = "true" ]; then
    update_story_status "$story_id" "completed"
    echo -e "   ${GREEN}✓${NC} Worker $worker_id: ${BOLD}$story_id${NC} completed - $title (${mins}m ${secs}s)"
  else
    # Check for errors in log
    if grep -q -i "error\|failed\|exception" "$log_file" 2>/dev/null; then
      update_story_status "$story_id" "failed"
      echo -e "   ${RED}✗${NC} Worker $worker_id: ${BOLD}$story_id${NC} failed - $title (${mins}m ${secs}s)"
    else
      # Not passed but no errors - might need retry
      update_story_status "$story_id" "pending"
      echo -e "   ${YELLOW}↺${NC} Worker $worker_id: ${BOLD}$story_id${NC} needs retry - $title (${mins}m ${secs}s)"
    fi
  fi

  # Clean up worker tracking
  unset "WORKER_PIDS[$worker_id]"
  unset "WORKER_STORIES[$worker_id]"
  unset "WORKER_LOGS[$worker_id]"
  unset "WORKER_START_TIMES[$worker_id]"
}

# Count active workers
count_active_workers() {
  local count=0
  for wid in ${(k)WORKER_PIDS}; do
    if kill -0 "${WORKER_PIDS[$wid]}" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Find an available worker slot
find_available_worker_slot() {
  for ((i=1; i<=MAX_PARALLEL_WORKERS; i++)); do
    if [ -z "${WORKER_PIDS[$i]}" ]; then
      echo "$i"
      return 0
    fi
  done
  echo "0"
  return 1
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

# Create empty PRD JSON if it doesn't exist but we have a PRD markdown file
if [ ! -f "$PRD_FILE" ]; then
  if [ -n "$PRD_MD_FILE" ] && [ -f "$PRD_MD_FILE" ]; then
    echo -e "${YELLOW}📄 Creating empty smd-prd.json (will be populated by /smd-convert)${NC}"
    echo '{"description": "", "branchName": "", "userStories": []}' > "$PRD_FILE"
  else
    echo -e "${RED}Error: PRD file not found at $PRD_FILE${NC}"
    echo "Run /smd-prd first to generate the PRD file, then /smd-convert to create the JSON."
    exit 1
  fi
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
  echo -n "Switch to $PRD_BRANCH? (y/n) "
  read -rsk1 REPLY
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
echo -e "${BOLD}✅ Starting Simply Done${NC} - Parallel Mode (max $MAX_PARALLEL_WORKERS workers)"
echo -e "${DIM}Max iterations: $MAX_ITERATIONS${NC}"

# Show initial state
show_parallel_status

# Main parallel execution loop
iteration=0
while [ $iteration -lt $MAX_ITERATIONS ]; do
  iteration=$((iteration + 1))

  # Get current counts
  COUNTS=$(get_story_counts)
  PASSED=$(echo "$COUNTS" | cut -d'|' -f1)
  TOTAL=$(echo "$COUNTS" | cut -d'|' -f2)

  # Check if all done
  if [ "$PASSED" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 All tasks completed!${NC}"
    echo "<promise>COMPLETE</promise>"
    exit 0
  fi

  # Display iteration header
  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "  ${BOLD}Iteration $iteration of $MAX_ITERATIONS${NC} │ Progress: ${GREEN}$PASSED${NC}/$TOTAL"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
  echo ""

  # Show current status
  show_parallel_status

  # Count active workers
  active_workers=$(count_active_workers)

  # Get stories ready to run
  ready_stories=$(get_ready_stories)
  ready_count=$(echo "$ready_stories" | grep -c . 2>/dev/null) || ready_count=0

  echo ""
  if [ "$ready_count" -eq 0 ] && [ "$active_workers" -gt 0 ]; then
    echo -e "  ${DIM}Running: $active_workers workers | Queued: 0 (waiting for current tasks to finish)${NC}"
  elif [ "$ready_count" -eq 0 ]; then
    echo -e "  ${DIM}Running: $active_workers workers | Queued: 0${NC}"
  else
    echo -e "  ${DIM}Running: $active_workers workers | Queued: $ready_count (ready to start)${NC}"
  fi
  echo ""

  # Start new workers if slots available
  while [ "$active_workers" -lt "$MAX_PARALLEL_WORKERS" ]; do
    # Get next ready story
    story_id=$(echo "$ready_stories" | head -1)

    if [ -z "$story_id" ]; then
      break
    fi

    # Remove this story from ready list
    ready_stories=$(echo "$ready_stories" | tail -n +2)

    # Find available worker slot
    worker_id=$(find_available_worker_slot)
    if [ "$worker_id" = "0" ]; then
      break
    fi

    story_title=$(get_story_title "$story_id")
    echo -e "   ${YELLOW}→${NC} Starting Worker $worker_id: ${BOLD}$story_id${NC} - $story_title"
    start_worker "$worker_id" "$story_id" "$story_title"
    active_workers=$((active_workers + 1))
  done

  # If no workers running and no ready stories, check for issues
  active_workers=$(count_active_workers)
  if [ "$active_workers" -eq 0 ]; then
    # Check for failed stories
    failed_count=$(jq '[.userStories[] | select(.status == "failed")] | length' "$PRD_FILE" 2>/dev/null || echo "0")
    if [ "$failed_count" -gt 0 ]; then
      echo -e "   ${RED}Warning: $failed_count stories failed. Review logs in .smd/.smd-worker-*.log${NC}"
    fi

    # Check for pending stories that can't run (dependency issues)
    pending_count=$(jq '[.userStories[] | select((.status == "pending") or (.status == null and (.passes | not)))] | length' "$PRD_FILE" 2>/dev/null || echo "0")
    ready_count=$(echo "$(get_ready_stories)" | grep -c . 2>/dev/null) || ready_count=0

    if [ "$pending_count" -gt 0 ] && [ "$ready_count" -eq 0 ]; then
      echo -e "   ${RED}Warning: $pending_count stories pending but none ready. Check dependencies.${NC}"
      echo -e "   ${DIM}This may indicate circular dependencies or missing prerequisite completions.${NC}"
    fi

    # Nothing more we can do
    if [ "$PASSED" -lt "$TOTAL" ]; then
      echo ""
      echo -e "${RED}⚠️  No stories can be started. Check for dependency issues or failures.${NC}"
      exit 1
    fi
    break
  fi

  # Wait for at least one worker to complete
  echo -e "   ${DIM}Waiting for workers to complete...${NC}"
  while true; do
    sleep 2

    # Update live status display
    show_worker_status_line

    # Check each worker for completion
    completed_any=false
    for wid in ${(k)WORKER_PIDS}; do
      if check_worker_done "$wid"; then
        echo ""  # New line after status line
        process_worker_completion "$wid"
        completed_any=true
      fi
    done

    # If any worker completed, break to start new iteration
    if [ "$completed_any" = true ]; then
      break
    fi

    # Also check if all workers are done
    active_workers=$(count_active_workers)
    if [ "$active_workers" -eq 0 ]; then
      echo ""  # New line after status line
      break
    fi
  done

  sleep 1
done

# Final status check
COUNTS=$(get_story_counts)
PASSED=$(echo "$COUNTS" | cut -d'|' -f1)
TOTAL=$(echo "$COUNTS" | cut -d'|' -f2)

if [ "$PASSED" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
  echo ""
  echo -e "${GREEN}🎉 All tasks completed!${NC}"
  exit 0
fi

echo ""
echo -e "${RED}⚠️  Reached max iterations ($MAX_ITERATIONS) without completing all tasks.${NC}"
echo -e "${DIM}Progress: $PASSED/$TOTAL completed${NC}"
echo -e "${DIM}Progress file: $PROGRESS_FILE${NC}"
echo -e "${DIM}Worker logs: $SMD_DIR/.smd-worker-*.log${NC}"
exit 1
