---
name: smd-convert
description: Convert PRDs to smd-prd.json format for autonomous agent execution. Use when transforming markdown PRDs into structured JSON for the Simply Done automation tool. USAGE /smd-convert [path-to-prd.md]
---

Or without argument to convert the most recent PRD in `tasks/`.

## Purpose

Transform markdown PRDs into structured JSON that Simply Done can process iteratively.

## Key Principles

### Story Sizing
Each user story must be completable in a single context window. Oversized stories cause failures - if a story is too big, the LLM runs out of context and produces broken code.

**Good story size:**
- Add a database column
- Create one API endpoint
- Build one UI component
- Add form validation

**Too big:**
- "Implement entire authentication system"
- "Build complete dashboard"

### Dependency Ordering
Stories execute sequentially by priority. Dependencies must flow logically:
1. Database changes first
2. Backend logic second
3. UI components third
4. Integration/aggregation last

### Verifiable Criteria
Acceptance criteria must be checkable:

- "Works correctly"
- "Good performance"
+ "Add status column with default 'pending'"
+ "API returns 200 with user list"
+ "Form shows validation error for empty email"

## Output Format

```json
{
  "project": "your-project",
  "branchName": "smd/feature-name",
  "description": "Brief feature description",
  "userStories": [
    {
      "id": "US-001",
      "title": "Story title",
      "description": "As a [user], I want [goal] so that [benefit]",
      "acceptanceCriteria": [
        "Specific criterion 1",
        "Specific criterion 2",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

## Required Criteria

Every story must include:
- "Typecheck passes" as final criterion

UI stories must also include:
- "Verify visually in browser"

## Workflow

1. Read the source PRD markdown
2. Break into small, atomic user stories
3. Order by dependencies (priority 1, 2, 3...)
4. Add implementation hints to `notes` field (see below)
5. Archive any existing `smd-progress.txt` if branch changed

## Notes Field Guidelines

The `notes` field helps the agent understand context. Include:

**Good notes:**
- "Use existing AuthContext from src/contexts/auth.tsx"
- "Follow pattern from UserService for error handling"
- "Database uses snake_case, TypeScript uses camelCase"
- "Must handle both logged-in and guest users"

**What NOT to put in notes:**
- Vague instructions: "Make it work well"
- Redundant info already in criteria
- Full implementation code (too long)

## Running Simply Done

After creating a PRD with `/smd-prd`, you can run Simply Done directly:

```bash
# Start with a specific PRD file (auto-converts if needed)
./smd.sh tasks/smd-prd-feature-name.md

# With custom max iterations
./smd.sh tasks/smd-prd-feature-name.md 30

# Or run without arguments to select from available PRDs
./smd.sh
```

The script will automatically run `/smd-convert` if `smd-prd.json` has no user stories.
