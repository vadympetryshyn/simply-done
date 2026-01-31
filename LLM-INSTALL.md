# Simply Done - AI Installation Instructions

When a user provides this file to Claude Code, follow these steps to install Simply Done in their project.

## Step 1: Clone Simply Done Repository

```bash
git clone https://github.com/vadympetryshyn/simply-done.git /tmp/simply-done
```

## Step 2: Install Skills

Copy the skills to the project's `.claude` directory:

```bash
mkdir -p .claude/skills
cp -r /tmp/simply-done/skills/* .claude/skills/
```

## Step 3: Copy Project Files

Copy all Simply Done files to `.smd` directory:

```bash
# Create .smd directory and copy all files there
mkdir -p .smd/tasks
cp /tmp/simply-done/smd.sh .smd/
cp /tmp/simply-done/smd-prompt.md .smd/
cp /tmp/simply-done/smd-prd.json .smd/
touch .smd/smd-progress.txt
chmod +x .smd/smd.sh
```

## Step 4: Verify Dependencies

Check that required dependencies are installed:

1. **Claude Code CLI** - Should already be available (you're running in it)
2. **jq** - JSON processor
   - macOS: `brew install jq`
   - Linux: `apt install jq` or `yum install jq`

Run: `command -v jq` to verify jq is installed.

## Step 5: Cleanup

```bash
rm -rf /tmp/simply-done
```

## Usage Instructions

After installation, tell the user:

### Getting Started

1. **Generate a PRD** - Run this Claude Code skill to create a Product Requirements Document:
   ```
   /smd-prd [describe your feature, bug, or task]
   ```
   Example: `/smd-prd Add user authentication with email/password`

   This saves the PRD to `.smd/tasks/smd-prd-[feature-name].md`

2. **Run the autonomous loop** - In your terminal (not Claude Code):
   ```bash
   .smd/smd.sh tasks/smd-prd-[feature-name].md
   ```
   The script automatically converts the PRD to JSON and starts the autonomous agent.

   Or run without arguments to select from available PRDs:
   ```bash
   .smd/smd.sh
   ```

### Tips

- Each story runs in a separate Claude session with fresh context
- Progress is saved automatically - you can stop and resume anytime with `.smd/smd.sh`
- Review changes before committing (changes are staged but not committed)
- Check `.smd/smd-progress.txt` for learnings between sessions

### Files Created

| File | Purpose |
|------|---------|
| `.smd/smd.sh` | The autonomous loop script |
| `.smd/smd-prompt.md` | Instructions for each Claude session |
| `.smd/smd-prd.json` | Current PRD in structured format |
| `.smd/smd-progress.txt` | Learnings and notes between sessions |
| `.smd/tasks/` | PRD markdown files |

### Troubleshooting

- **Script fails immediately**: Run `brew install jq` (macOS) or `apt install jq` (Linux)
- **Story keeps failing**: Break it into smaller pieces in the PRD
- **Context exhausted**: Story is too large - split it up
- **Resume after stopping**: Just run `./smd.sh` again

For more details, see the README at: https://github.com/vadympetryshyn/simply-done
