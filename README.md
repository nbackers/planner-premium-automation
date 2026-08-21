# Planner Premium Automation - Escalate a card to your manager's 1:1

Automate Microsoft Planner Premium (Project for the web) with Power Automate, using the
**Dataverse** connector - because the Planner connector cannot see Premium plans at all.

Ships as an importable managed solution, configured entirely through environment variables.
No flow editing required.

---

## The problem

Two problems, one small and one large.

**The immediate one.** Team leads run 1:1s from a Planner board. When something needs to go up a
level, the only options are to retype the card into the manager's 1:1 plan, or to remember to raise
it verbally. Both fail in the same way: the item is either lost, or duplicated across two boards
that immediately drift apart. Escalation is the most important thing a 1:1 produces and it's the
part with no supporting tooling.

**The one that actually blocks people.** Almost every attempt to automate Planner Premium fails at
the first step, because:

> **The `shared_planner` connector does not work with Planner Premium.**

The Planner connector talks to Planner Basic - Group-backed plans behind the Graph `/planner`
endpoints. Planner **Premium** plans are Project for the web plans, and they live in **Dataverse**,
in your tenant's default environment, as `msdyn_project*` tables. The connector cannot see them.

So people try the Planner actions, get empty results or errors, and conclude Planner Premium can't
be automated. It can - through an entirely different connector, against tables that aren't
obviously documented as being Planner at all.

## What this solves

| Problem | How this repo solves it |
|---|---|
| Planner connector returns nothing for Premium plans | Builds on the **Dataverse** connector against `msdyn_project*` |
| No published mapping of Planner UI concepts to tables | Full mapping table, taken from live metadata |
| Escalated cards get retyped or lost | Trigger copies the card automatically on bucket move |
| Naive automations create endless duplicates | Dedupe guard - 9 trigger fires produced exactly 3 cards |
| Automations fire on their own writes and loop | Documented loop-guard behaviour and how to keep it |
| Handover to a non-technical owner | Four environment variables set at import; no flow editing |
| Can't test without a Premium licence | Mock schema + seed scripts reproduce the tables |

---

## How it works

```
Planner Premium UI              Dataverse                    Power Automate
─────────────────────           ─────────────────            ────────────────────────
Drag card to "Escalate"   ──►   msdyn_projecttask   ──────►  Trigger: row modified
bucket                          row updated                          │
                                                                     ▼
                                                            Is it in the Escalate
                                                            bucket?           │ no ──► stop
                                                                     │ yes
                                                                     ▼
                                                            Already copied?   │ yes ─► stop
                                                                     │ no
                                                                     ▼
                                                            Project Schedule API
                                                            creates the copy
                                                                     │
Card appears in manager's  ◄────  msdyn_projecttask  ◄───────────────┘
1:1 plan                          row created
```

### Planner Premium → Dataverse mapping

| Planner Premium UI | Dataverse table | Entity set |
|---|---|---|
| Plan | `msdyn_project` | `msdyn_projects` |
| Card / Task | `msdyn_projecttask` | `msdyn_projecttasks` |
| Bucket | `msdyn_projectbucket` | `msdyn_projectbuckets` |
| Assignment | `msdyn_resourceassignment` | `msdyn_resourceassignments` |
| Plan membership | `msdyn_projectteam` | `msdyn_projectteams` |

Task and plan names are `msdyn_subject`. Bucket name is `msdyn_name`. This inconsistency costs
people hours.

---

## Install

1. Create a bucket named `Escalate` in the source plan, and `Escalated from team` in the target plan.
2. Import `solution/PlannerPremiumEscalate_2_0_0_0.zip` into the environment holding your Planner
   Premium data - normally the **default** environment.
3. Enter your four plan and bucket names when prompted at import.
4. Turn the flow on. It ships disabled deliberately.

Full walkthrough for non-technical owners: **[docs/setup-guide.md](docs/setup-guide.md)**
Architecture, design decisions and gotchas: **[docs/technical-design.md](docs/technical-design.md)**

> **Environment matters.** Dataverse triggers cannot fire on changes in another environment - only
> actions can read across. Install this alongside the data or it will import cleanly and never run.

---

## Design decisions

**Bucket-driven, not label-driven.** Planner's coloured labels are a Planner-layer concept with no
corresponding filterable column on `msdyn_projecttask` - verified against live metadata. A
label-based trigger has nothing to filter on. Dragging a card into a bucket is also more visible to
the user. Custom-column and naming-convention alternatives are documented as Options B and C.

**Environment variables, not hardcoded IDs.** The four plan and bucket names are set at import.
The owner never opens the flow, and changing a name later doesn't require editing it.

**Ships disabled.** Nothing runs until the configuration has been checked.

**Dedupe by recorded origin.** Each copy records the card it came from, so re-escalating the same
card never creates a second copy.

---

## What is and isn't proven

Stated precisely, because the difference matters.

**Verified against real `msdyn_project*` tables:** the schema and entity set names (from live
metadata, not documentation); that `msdyn_projecttask` and `msdyn_projectbucket` reject direct
creates; that bucket names use `msdyn_name` while plans and tasks use `msdyn_subject`; that there is
no label column; and that the solution ZIP imports cleanly with the correct trigger and conditions.

**Verified against mock tables** (9 runs, 3 cards created): the trigger fires on bucket move, the
dedupe guard holds, and the flow does not loop on its own writes.

**Not verified:** the three Project Schedule API calls have not been executed against a full Project
install; and that `msdyn_projectname` / `msdyn_projectbucketname` are populated in the trigger
payload. If the flow never fires, check that first and swap to `_msdyn_projectbucket_value` against
the bucket GUID.

---

## Scripts

| Script | Purpose |
|---|---|
| `Build-DistributableSolution.ps1` | Builds, exports, injects the Schedule API definition, repacks and verifies |
| `Discover-PlannerPremiumSchema.ps1` | Dumps real table/column/lookup names from an environment |
| `Test-EscalateSolution.ps1` | Seeds plans, buckets and cards for an end-to-end test |
| `Build-MockPlannerSchema.ps1` | Creates mock tables mirroring the schema - **test without a Premium licence** |
| `Seed-MockPlannerData.ps1` | Seeds the two-plan 1:1 scenario |

All take `-OrgUrl` and are idempotent.

---

## Licensing gotcha

Reading and writing `msdyn_*` tables needs a Project Plan 3 / Planner Premium licence on the flow's
connection identity - a Power Automate licence alone is not enough.

Check **bundled service plans**, not top-level SKU names. `PROJECT_FOR_PROJECT_OPERATIONS` and
`PROJECT_ESSENTIALS` frequently sit inside another licence and are already provisioned:

```http
GET https://graph.microsoft.com/v1.0/subscribedSkus
```

Then inspect each `servicePlans[]`. Getting this wrong is the most common reason people conclude
the work is impossible when it isn't.

Entitlement is also separate from provisioning - `msdyn_project*` tables only appear once the
Project app is **installed into that specific environment**.

---

## Limitations
- Copies the card **title** plus an origin note. Not checklists, attachments, assignees or due dates.
- One-way copy. Later edits to the original don't update the copy.
- Dragging a card out of `Escalate` does not remove the copy.
- Allow 30-60 seconds between the change and the copy appearing.
- Buckets must be created by hand - Planner Premium doesn't allow automated bucket creation.

**Privacy:** card titles are copied into a plan the manager can see.

---

## Licence

MIT - see [LICENSE](LICENSE).
