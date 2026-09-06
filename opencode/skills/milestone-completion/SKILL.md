---
name: milestone-completion
description: Complete, verify, and close software milestones safely. Use this skill whenever the user asks to implement, finish, verify, close, or declare a milestone, phase, epic, checklist, or planned work item complete, especially when a plan or acceptance checklist exists. Inspect the plan first, update its checklist only from evidence, run project-specific gates, and report proof and remaining blockers.
---

# Milestone completion

Treat milestone completion as an evidence task, not a progress claim. A milestone is complete only when its implementation, acceptance criteria, checklist, and validation agree.

## Workflow

1. **Locate governing plan**
   - Find the repository's milestone, roadmap, plan, or checklist file.
   - Read the relevant milestone section and any repository instructions before editing.
   - If no checklist exists, derive explicit acceptance criteria from the user's request and existing project documentation; do not invent broad scope.
   - Inspect current git status and preserve unrelated user changes.

2. **Map acceptance criteria to proof**
   - Turn each criterion into a checkable statement.
   - Trace each statement to the owning code, configuration, generated artifact, test, or documentation.
   - Identify missing implementation, stale checklist marks, and criteria blocked by environment or external prerequisites.
   - Separate observed facts from assumptions.

3. **Implement only requested scope**
   - If user asked to implement or finish the milestone, complete missing criteria through the repository's existing seams and conventions.
   - If user asked only to verify, do not modify product code or add unrelated polish.
   - Preserve existing data, generated-file rules, and unrelated working-tree changes.
   - Ask before destructive or outward-facing actions. Do not commit, push, merge, publish, or delete unless explicitly authorized.

4. **Validate in increasing cost order**
   - Run focused tests or checks nearest to changed behavior first.
   - Run formatting and static analysis required by project instructions.
   - Run generated-code checks when annotations or generated files are involved; never hand-edit generated output.
   - Run the nearest integration tests, then the full project gate when practical.
   - Use commands from repository instructions and run them from the correct project root.
   - Record exact pass, fail, unavailable, and blocked results. A skipped check is not a pass.

5. **Reconcile checklist**
   - Re-read the relevant plan section after implementation and validation.
   - Mark `[x]` only criteria directly supported by current evidence.
   - Leave incomplete or blocked criteria unchecked and add a short factual reason when the plan supports notes.
   - Never mark a parent milestone complete while any required child criterion remains unchecked, failed, or unverified.
   - Do not rewrite unrelated checklist entries.

6. **Stop at completion boundary**
   - Stop when all requested criteria have proof and checklist state is accurate.
   - Do not continue into the next milestone or add speculative polish.

## Handling blockers

- **Test or analysis failure:** inspect and fix when implementation was requested; rerun affected checks. If still failing, keep milestone incomplete and report failure.
- **Environment failure:** distinguish toolchain, native library, network, credentials, or platform limitation from product regression. Do not mark the criterion complete.
- **Missing acceptance detail:** use repository conventions and existing plan language; ask the user only when different interpretations would change implementation.
- **Pre-existing changes:** do not overwrite or clean them. Mention relevant overlap if it affects proof.

## Completion report

Use this structure:

```text
Milestone: <name or number>
Status: complete | incomplete | blocked

Checklist:
- [x] <criterion> - <proof>
- [ ] <criterion> - <remaining issue or blocker>

Validation:
- `<command>` - pass | fail | blocked (<short decisive result>)

Changed:
- <file or behavior>

Remaining:
- <none, or concrete next action>
```

Only say `complete` when checklist and validation support it. Report paths, commands, and concise evidence so another person can reproduce the conclusion.
