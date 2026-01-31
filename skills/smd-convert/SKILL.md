---
name: smd-convert
description: Convert PRDs to smd-prd.json format for autonomous agent execution. Use when transforming markdown PRDs into structured JSON for the Simply Done automation tool. USAGE /smd-convert [path-to-prd.md]
---

Or without argument to convert the most recent PRD in `.smd/tasks/`.

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

Save as `.smd/smd-prd.json` in the **`.smd` directory**.

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
      "notes": "",
      "dependencies": [],
      "status": "pending"
    }
  ]
}
```

## Dependency Detection (for Parallel Execution)

Simply Done can run up to 5 stories in parallel. Stories with no dependencies or satisfied dependencies run simultaneously.

### New Fields

- **`dependencies`**: Array of story IDs that must complete before this story can start
- **`status`**: Current execution status - "pending", "in_progress", "completed", "failed"

### Dependency Rules

1. **Database → Backend**: Schema changes must complete before API endpoints using them
2. **Backend → Frontend**: API endpoints must exist before UI components calling them
3. **Shared Components**: If US-002 uses a component created in US-001, add `"dependencies": ["US-001"]`
4. **Independent Stories**: Stories touching different parts of the codebase can run in parallel

### Example with Dependencies

```json
{
  "userStories": [
    {
      "id": "US-001",
      "title": "Add tasks table to database",
      "dependencies": [],
      "status": "pending"
    },
    {
      "id": "US-002",
      "title": "Create GET /api/tasks endpoint",
      "dependencies": ["US-001"],
      "status": "pending"
    },
    {
      "id": "US-003",
      "title": "Create POST /api/tasks endpoint",
      "dependencies": ["US-001"],
      "status": "pending"
    },
    {
      "id": "US-004",
      "title": "Build task list component",
      "dependencies": ["US-002"],
      "status": "pending"
    },
    {
      "id": "US-005",
      "title": "Build add task form",
      "dependencies": ["US-003"],
      "status": "pending"
    }
  ]
}
```

**Parallel execution visualization:**
```
Batch 1: US-001 (alone - database)
Batch 2: US-002, US-003 (parallel - both depend only on US-001)
Batch 3: US-004, US-005 (parallel - independent after their deps complete)
```

### Dependency Analysis Checklist

When converting a PRD, for each story ask:
1. What does this story create? (tables, APIs, components)
2. What does this story use? (from other stories)
3. Can this run simultaneously with other stories? (no shared file modifications)

## Required Criteria

Every story must include:
- "Typecheck passes" as final criterion

## Workflow

1. Read the source PRD markdown
2. Break into small, atomic user stories
3. Order by dependencies (priority 1, 2, 3...)
4. Add implementation hints to `notes` field (see below)
5. Archive any existing `.smd/smd-progress.txt` if branch changed

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
.smd/smd.sh tasks/smd-prd-feature-name.md

# With custom max iterations
.smd/smd.sh tasks/smd-prd-feature-name.md 30

# Or run without arguments to select from available PRDs
.smd/smd.sh
```

The script will automatically run `/smd-convert` if `.smd/smd-prd.json` has no user stories.
