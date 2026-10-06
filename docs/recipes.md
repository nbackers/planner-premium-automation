# Recipes

Six automations built from the same parts: a constrained trigger, a condition, an action, and a
guard. One of them is the worked example in `solution/`. The rest are **designs, not built**. Each
reuses the patterns in [automation-patterns.md](automation-patterns.md), and most need far less than
the worked example because they never write to a Planner table.

Column names below are the usual ones for `msdyn_projecttask`. Confirm them in your tenant with
`.\scripts\Discover-PlannerPremiumSchema.ps1` before building; column sets differ.

| # | Recipe | Writes to Planner? | Schedule API? | Built |
|---|---|---|---|---|
| 1 | [Overdue digest](#1-overdue-digest) | No | No | Design |
| 2 | [Blocked-bucket alert](#2-blocked-bucket-alert) | No | No | Design |
| 3 | [Status roll-up to a business record](#3-status-roll-up-to-a-business-record) | No | No | Design |
| 4 | [Copy a card to another plan](#4-copy-a-card-to-another-plan) | Creates a task | Yes | **Built and import-tested** |
| 5 | [Plan from a template](#5-plan-from-a-template) | Creates tasks | Yes | Design |
| 6 | [Assign a reviewer on bucket entry](#6-assign-a-reviewer-on-bucket-entry) | Creates an assignment | Yes | Design |

Start with recipes 1 to 3 if you are new to Planner Premium automation. They prove connectivity,
trigger behaviour and the table map with no Schedule API risk at all.

---

## 1. Overdue digest

**Problem.** Overdue cards are visible only to someone who opens the plan.

| Part | Design |
|---|---|
| Trigger | Recurrence, weekdays at 08:00 |
| Read | List rows on `msdyn_projecttasks`: `msdyn_scheduledend lt @{utcNow()}` and `msdyn_progress lt 100`, filtered to the plans in an environment variable |
| Shape | Group by plan, then by assignee from `msdyn_resourceassignments` |
| Action | One Teams message or email per plan owner, listing overdue cards with links |
| Guard | None needed. A digest is idempotent by design |

**Watch.** `msdyn_progress` may be stored as 0 to 100 or 0 to 1 depending on the release. Check a
known card before writing the filter.

## 2. Blocked-bucket alert

**Problem.** A card moved to *Blocked* sits there until the next stand-up.

| Part | Design |
|---|---|
| Trigger | Dataverse *When a row is modified* on `msdyn_projecttask`, **select columns** `msdyn_projectbucket` only |
| Condition | Bucket name equals the environment variable `BlockedBucketName` (or compare `_msdyn_projectbucket_value` to an id) |
| Action | Post an Adaptive Card to the team's channel with the card title, plan and a link |
| Guard | A row in your own `Notification log` table keyed on task id + bucket id, checked before posting |

The guard lives in **your** table, not on the task, so no Schedule API is needed. Without it, every
scheduling-engine rewrite of the task re-fires the alert. See pattern 3, *Guard against duplicates*.

## 3. Status roll-up to a business record

**Problem.** A case, project or request in another system has a Planner plan behind it, and nobody
updates the parent when work progresses.

| Part | Design |
|---|---|
| Trigger | Dataverse *When a row is modified* on `msdyn_projecttask`, select columns `msdyn_progress` |
| Read | All tasks in the same plan; compute percent complete and the latest `msdyn_scheduledend` |
| Action | Update the parent record **in your own table** (or call the other system's API) |
| Guard | Only write when the computed values differ from what is stored |

Link the plan to the parent with a lookup or a stored plan id on the parent. Writes go to your table,
so the Schedule API is not involved.

## 4. Copy a card to another plan

The worked example. When a card lands in a named bucket, a copy is created in another plan. See
[example-escalation.md](example-escalation.md) and [example-setup-guide.md](example-setup-guide.md).

It uses every pattern: a constrained trigger, a name-based condition from environment variables, a
dedupe guard, and the three-step Schedule API create.

## 5. Plan from a template

**Problem.** Every new starter, store opening or customer onboarding needs the same twenty tasks, and
someone copies them by hand.

| Part | Design |
|---|---|
| Trigger | A row created in your own request table, for example *New starter* |
| Read | Template tasks from a configuration table: title, bucket, offset in days from the start date |
| Action | `msdyn_CreateProjectV1` for the plan, then one operation set with `msdyn_PssCreateV1` per bucket and task, then `msdyn_ExecuteOperationSetV1` |
| Guard | A *plan created* flag on the request row, set only after the operation set succeeds |

**Watch.** `msdyn_CreateProjectV1` runs immediately and cannot go inside the operation set; create the
plan first, then stage the rest. Keep tasks per operation set modest and check the execute step's
output for the real error.

## 6. Assign a reviewer on bucket entry

**Problem.** Cards moved to *Ready for review* wait for someone to notice and pick them up.

| Part | Design |
|---|---|
| Trigger | As recipe 2, on bucket change |
| Condition | Bucket is `ReviewBucketName`, and the card has no reviewer assigned |
| Read | The reviewer for this plan from configuration, and their `msdyn_projectteam` row |
| Action | If not a team member, `msdyn_CreateTeamMemberV1`. Then an operation set with `msdyn_PssCreateV1` for a `msdyn_resourceassignment` |
| Guard | Check for an existing assignment for that reviewer before creating |

**Watch.** Resource assignments cannot be updated through the Schedule API, only created and
deleted, and several fields (`Effort`, `EffortCompleted`, `EffortRemaining`, `PlannedWork`) are not
supported. This is the most involved recipe; build it last.

---

## Choosing between them

If the outcome is *someone finds out*, you need recipes 1 to 3 and no writes. If the outcome is *the
plan changes*, you need the Schedule API, and recipe 4 is the tested starting point for that shape.
