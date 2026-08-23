<div align="center">

# Planner Premium Automation Starter Kit

**Automate any Planner Premium process, using the Dataverse connector**

[![Connectivity check](https://img.shields.io/badge/connectivity-check_included-success?style=flat-square)](scripts/)
[![Mock schema](https://img.shields.io/badge/testable-without_Premium_licence-success?style=flat-square)](scripts/)
[![Power Automate](https://img.shields.io/badge/Power_Automate-0066FF?style=flat-square&logo=microsoftpowerautomate&logoColor=white)](#)
[![Dataverse](https://img.shields.io/badge/Dataverse-0078D4?style=flat-square)](#)
[![Sample code](https://img.shields.io/badge/sample_code-not_production_ready-orange?style=flat-square)](#disclaimer)
[![Licence](https://img.shields.io/badge/licence-MIT-blue?style=flat-square)](LICENSE)

</div>

Connectivity validation, the table reference, the patterns that any Planner Premium automation
needs, and one worked example that proves them end to end.

---

## The problem

> **The Planner connector does not work with Planner Premium.**

The `shared_planner` connector talks to Planner Basic: Group-backed plans behind the Graph
`/planner` endpoints. Planner **Premium** plans are Project for the web plans, and they live in
**Dataverse**, in your tenant's default environment, as `msdyn_project*` tables.

So people try the Planner actions, get empty results or errors, and conclude Planner Premium cannot
be automated. It can, through an entirely different connector, against tables that are not obviously
documented as being Planner at all.

Then a second wall: the environment. Planner Premium writes only to the tenant **default**
environment. Point a flow at a dev environment and you get zero rows and no error.

## What this gives you

A starting point for **any** Planner Premium automation, not one finished solution.

| You need | Where |
|---|---|
| Does this environment even work? | [`Test-PlannerPremiumConnectivity.ps1`](scripts/Test-PlannerPremiumConnectivity.ps1) |
| Which tables and columns do I use? | [docs/table-reference.md](docs/table-reference.md) |
| What does my own environment actually contain? | [`Discover-PlannerPremiumSchema.ps1`](scripts/Discover-PlannerPremiumSchema.ps1) |
| How do I build this without it duplicating or looping? | [docs/automation-patterns.md](docs/automation-patterns.md) |
| Can I test before I have licences? | Mock schema scripts |
| What does a finished one look like? | [docs/example-escalation.md](docs/example-escalation.md) |

---

## Start here

```powershell
az login --allow-no-subscriptions

# 1. Is this environment viable?
.\scripts\Test-PlannerPremiumConnectivity.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
```

The check answers, in order: can I authenticate, are the Project tables present, is there data, can
I write, and which columns will my flow use. Every call is read-only.

```
1. Authentication
  [PASS] Token acquired
  [PASS] Environment reachable

2. Project for the web tables
  [PASS] msdyn_project present          entity set: msdyn_projects
  [PASS] msdyn_projecttask present      entity set: msdyn_projecttasks
  [PASS] msdyn_projectbucket present    entity set: msdyn_projectbuckets

3. Plan and task data
  [PASS] 4 plan(s) visible

4. Write capability
  [PASS] Project Schedule API operations present

READY - this environment can support Planner Premium automation.
```

If it fails, the output tells you why and what to do next. The most common result is the wrong
environment, and the check says so explicitly rather than leaving you to guess.

```powershell
# 2. Dump the full schema for your own tenant
.\scripts\Discover-PlannerPremiumSchema.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
```

---

## The mapping

| Planner Premium UI | Dataverse table | Entity set |
|---|---|---|
| Plan | `msdyn_project` | `msdyn_projects` |
| Card / Task | `msdyn_projecttask` | `msdyn_projecttasks` |
| Bucket | `msdyn_projectbucket` | `msdyn_projectbuckets` |
| Assignment | `msdyn_resourceassignment` | `msdyn_resourceassignments` |
| Plan membership | `msdyn_projectteam` | `msdyn_projectteams` |

Plans and tasks use `msdyn_subject` for their display name. Buckets use **`msdyn_name`**. That
inconsistency costs people time.

Full detail, query shapes and write restrictions: **[docs/table-reference.md](docs/table-reference.md)**

---

## The patterns

Whatever your process does, these apply. Full detail in
**[docs/automation-patterns.md](docs/automation-patterns.md)**.

**Trigger on a bucket or a custom column, not a label.** Planner's coloured labels have no
corresponding column on `msdyn_projecttask`, verified against live metadata, so a label-driven
trigger has nothing to filter on. This is the most common false start.

**Guard against duplicates.** The trigger fires on every qualifying change, not once per card.
Dragging a card out and back in fires it again. Record the source id and check for it before acting.
In the worked example the trigger fired 9 times and created exactly 3 records.

**Guard against loops.** If your flow writes to the table it triggers on, it will fire itself.

**Constrain the trigger columns.** Project's scheduling engine rewrites task rows far more often
than a human edits them.

**Configure, do not hardcode.** Plan and bucket GUIDs differ per environment. Use environment
variables so the solution survives a handover.

**Creating tasks needs the Project Schedule API.** `msdyn_projecttask` and `msdyn_projectbucket`
reject direct creates. Updates to existing tasks work normally, so if you only modify cards you can
skip that entirely.

---

## Test without a Premium licence

Build and validate the pattern before you have licences or a provisioned environment:

```powershell
.\scripts\Build-MockPlannerSchema.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
.\scripts\Seed-MockPlannerData.ps1   -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
.\scripts\Test-PlannerPremiumConnectivity.ps1 -OrgUrl https://... -MockPrefix cra89
```

The mock tables mirror the real shape closely enough to prove trigger, condition, dedupe and loop
behaviour. The one thing they cannot reproduce is the create restriction, since mock tables accept
direct creates.

---

## The worked example

`solution/PlannerPremiumEscalate_2_0_0_0.zip` copies a card into a second plan when it lands in a
named bucket. It exists to prove the patterns against something concrete, and as a base to retrofit.

Import it, set four names at import time, turn it on. It ships disabled deliberately.

- Non-technical walkthrough: [docs/example-setup-guide.md](docs/example-setup-guide.md)
- Build detail and design decisions: [docs/example-escalation.md](docs/example-escalation.md)

### Retrofitting it

| To change | Where |
|---|---|
| Which plan and bucket trigger it | Environment variables, at import |
| What condition fires it | The condition step |
| What it actually does | Replace the create step |
| Where the dedupe marker lives | The guard step |

The trigger, condition, dedupe guard and configuration pattern carry over unchanged. Usually only
the action in the middle is specific to your process.

---

## Scripts

| Script | Purpose |
|---|---|
| `Test-PlannerPremiumConnectivity.ps1` | Go/no-go check on an environment. Read-only |
| `Discover-PlannerPremiumSchema.ps1` | Dumps real table, column and lookup names |
| `Build-MockPlannerSchema.ps1` | Mock tables mirroring the schema, for testing without a licence |
| `Seed-MockPlannerData.ps1` | Seeds a two-plan scenario into the mock tables |
| `Build-DistributableSolution.ps1` | Builds, exports, repacks and verifies the example solution |
| `Test-ExampleSolution.ps1` | End-to-end test of the example |

All take `-OrgUrl` and are idempotent.

---

## What is and isn't verified

**Verified against real `msdyn_project*` tables:**

- Table names, entity set names, column names and lookup navigation properties, from live metadata
- `msdyn_projecttask` and `msdyn_projectbucket` **reject direct creates**; `msdyn_project` does not
- Bucket display name is `msdyn_name` while plans and tasks use `msdyn_subject`
- There is **no label or tag column** on `msdyn_projecttask`
- The example solution imports cleanly with the correct trigger, conditions and guard

**Verified against mock tables** (9 runs, 3 records created):

- The trigger fires on a bucket move
- The dedupe guard holds across repeated edits and re-triggering
- The flow does not loop on its own writes

**Verified for the connectivity check:**

- Correctly detects and explains a missing Project install
- Correctly reports a viable environment against a mock schema

**Not verified:**

- The three Schedule API calls have **not been executed**. The environment used for discovery had
  only a partial Project install, so `msdyn_CreateOperationSetV1`, `msdyn_PssCreateV1` and
  `msdyn_ExecuteOperationSetV1` were absent. Their shape follows Microsoft's documented walkthrough,
  but the first real run is yours.
- Whether `msdyn_projectname` and `msdyn_projectbucketname` are populated in the **trigger** payload.
  They exist on the table and Dataverse populates lookup name columns as standard, but the name-based
  condition depends on it. If a flow never fires on a genuine change, check this first and swap to
  `_msdyn_projectbucket_value` against the bucket GUID.
- Whether Planner Premium adds columns beyond what Project Operations installs.

---

## Licensing gotcha

Reading and writing `msdyn_*` tables needs a Project Plan 3 or Planner Premium licence on the flow's
connection identity. A Power Automate licence alone is not enough.

**Check bundled service plans, not top-level SKU names.** `PROJECT_FOR_PROJECT_OPERATIONS` and
`PROJECT_ESSENTIALS` frequently sit inside another licence and are already provisioned:

```http
GET https://graph.microsoft.com/v1.0/subscribedSkus
```

Then inspect each `servicePlans[]`. Getting this wrong is the most common reason people conclude the
work is impossible when it is not.

Entitlement is also separate from provisioning: `msdyn_project*` tables only appear once the Project
app is **installed into that specific environment**.

---

## Limitations

- Triggers cannot fire on changes in another environment. Install alongside the data, or poll.
- Allow 30 to 60 seconds between a change and the trigger firing.
- Buckets must be created by hand. Planner Premium does not allow automated bucket creation.
- The worked example copies a card title and an origin note, not checklists, attachments, assignees
  or due dates.

---

## Disclaimer

This is **sample code**, published as a reusable reference pattern.

- Provided **as is**, without warranty of any kind, express or implied. See [LICENSE](LICENSE).
- **Not production ready.** Treat it as a starting point, not a finished solution. Review, test and
  harden it against your own requirements before any real use.
- **Not an official Microsoft product** and not affiliated with, endorsed by, or supported by
  Microsoft. Product names are trademarks of their respective owners.
- **No support commitment.** Issues and pull requests are welcome, but nothing here carries an SLA.
- Some behaviours documented here rely on **undocumented or preview platform features** that can
  change without notice. Verify against current documentation before depending on them.
- You are responsible for security, privacy, licensing and regulatory compliance in your own
  environment.

---

## Licence

MIT - see [LICENSE](LICENSE).
