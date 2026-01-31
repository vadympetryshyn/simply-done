---
name: smd-prd
description: Generate Product Requirements Documents for new features/Tasks or bugs. USAGE /smd-prd [feature description]
---

## Guidelines

The final PRD will be splited to user stories and will be done as separate tickets in separate session one by one.

## Process

### Phase 0: Reset PRD State

Before starting, reset the `.smd/smd-prd.json` file to a clean state (create `.smd` directory if it doesn't exist):

```json
{
  "project": "simply-done",
  "branchName": "feature/simply-done",
  "description": "",
  "userStories": []
}
```

### Phase 1: Investigate code base

Enter planning mode.

Check details of project in CLAUDE.md.
Make research to understand what we have already implemented to perform this task, what you are gonna use and reuse, what we have and what don't have.

### Phase 2: Clarification

In planning mode ask questions to clarify anything that's unclear, don't make assumtions if you don't have some info.

### Phase 3: Generate PRD

Create a structured PRD with these sections:

1. **Overview** - Problem statement and feature description
2. **Goals** - Measurable, specific objectives
3. **User Stories** - Small, implementable tasks with acceptance criteria
4. **Functional Requirements** - Numbered, unambiguous specifications
5. **Implementation Details** - Services, utilities, routes, and special details of implementation
6. **Task Dependencies** - Important dependencies on previous or subsequent tasks
7. **Non-Goals** - Explicit scope boundaries
8. **Technical Considerations** - Architecture, performance, integrations
9. **Success Metrics** - How to measure completion
10. **Open Questions** - Remaining clarifications

## User Story Format

Each user story must be:
- Small enough to complete in one context window (~10-15 files to read, 2-5 files to modify)
- Have verifiable acceptance criteria (not vague)
- Include "Typecheck passes" as final criterion

### Good Story Examples

**Example 1: Database Story**
- Title: "Add status column to tasks table"
- Acceptance Criteria:
  - Migration adds `status` column with type `enum('pending', 'completed')`
  - Default value is 'pending'
  - Typecheck passes

**Example 2: API Story**
- Title: "Create GET /api/tasks endpoint"
- Acceptance Criteria:
  - Endpoint returns list of tasks as JSON
  - Returns 200 status code
  - Includes pagination (limit/offset)
  - Typecheck passes

**Example 3: UI Story**
- Title: "Add task status toggle button"
- Acceptance Criteria:
  - Toggle button appears next to each task
  - Clicking toggles between pending/completed
  - UI updates immediately without page reload
  - Typecheck passes

### Bad Story Examples (Too Large)

- "Implement user authentication" - spans DB, API, and UI
- "Build complete dashboard" - too many components
- "Add full CRUD for tasks" - should be 4 separate stories

## Output

Save as `.smd/tasks/smd-prd-[feature-name].md` (create `.smd/tasks` directory if it doesn't exist).

Ask user to review the PRD. If approved, suggest running:

```bash
.smd/smd.sh tasks/smd-prd-[feature-name].md
```

This will automatically convert the PRD to JSON and start the autonomous execution loop.

