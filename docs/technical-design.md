# Duplicate an "escalate" Planner Premium card into your 1:1-with-manager plan

## Just want to import it?

`PlannerPremiumEscalate_2_0_0_0.zip` is an unmanaged solution containing the flow, the dedupe
column, a connection reference and four environment variables. Hand it to someone with
`SETUP-GUIDE.md` and they can set it up without opening the flow.

The four settings are **plain text plan and bucket names**, not GUIDs:

| Setting | Example |
| --- | --- |
| Watch this plan | `1:1s with my team` |
| Escalate bucket | `Escalate` |
| Copy into this plan | `1:1 with my manager` |
| Bucket for copies | `Escalated from team` |

This is deliberate. Asking a non-developer to find four Dataverse GUIDs is the single biggest
barrier to hand-off. Names work because the trigger payload already carries the denormalised lookup
names — `msdyn_projectname` and `msdyn_projectbucketname` — so the "should I act?" decision costs no
extra queries. Only the target plan and bucket need resolving to GUIDs, and only on the rare
occasion a card is actually escalated.

If a name doesn't match, the flow **terminates with an explicit message** naming the setting to fix,
rather than silently doing nothing. A typo is the most likely setup mistake, so it fails loudly.

Verified: this ZIP imports successfully into a real Dataverse environment with the `msdyn_project*`
tables, and the flow arrives with the correct trigger, conditions, name lookups and guard intact.
It was *not* run end-to-end — see *What is and isn't proven*.

---

## Where the flow must live

**Install it in the same environment as the Planner Premium data** — normally the tenant's
**default** environment.

This isn't a preference. Per Microsoft's documentation on cross-environment Dataverse:

> "Support for triggering flows based on Dataverse changes from other environments isn't yet
> available."

Actions ending in *"…from selected environment"* can read across environments, but **triggers
cannot**. So a flow sitting in a dev environment pointed at the default environment cannot use the
real-time trigger at all — it has to fall back to a **Recurrence + List rows** polling loop, which
means delay, more API calls, and an extra connection-permissions problem in the target environment.

Installing into the data's own environment avoids all of that and is also simpler to hand over:
one connection, no environment picker, no org URL to configure.

---

## The core problem

The `shared_planner` connector only talks to **Planner Basic** (Group-backed plans, Graph
`/planner` endpoints). **Planner Premium** plans are Project for the web plans and live in
**Dataverse**, in your **tenant default environment**. So the automation is built entirely on the
**Microsoft Dataverse** connector, not the Planner connector.

Mapping between what your colleague sees and what's in Dataverse:

| Planner Premium UI | Dataverse table | Entity set (used in URLs) |
| --- | --- | --- |
| Plan | `msdyn_project` | `msdyn_projects` |
| Card / Task | `msdyn_projecttask` | `msdyn_projecttasks` |
| Bucket | `msdyn_projectbucket` | `msdyn_projectbuckets` |
| Assignment (who's on the card) | `msdyn_resourceassignment` | `msdyn_resourceassignments` |
| Plan membership | `msdyn_projectteam` | `msdyn_projectteams` |

Task name is `msdyn_subject` (NOT `name` or `subject`).

---

## Step 0 — find the right environment (do this first)

```powershell
pac org list
```

Planner Premium writes to the **default** environment. If you point the flow at the wrong one you
get zero rows and no error, which is the usual dead end.

Then confirm the tables are actually there:

```powershell
.\Discover-PlannerPremiumSchema.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
```

If it prints `msdyn_projecttask was NOT found`, you're on the wrong environment. If it prints the
column list, you're in business — and section 5 of its output dumps the **raw JSON of real cards**,
which is how you confirm exactly how the tag is stored.

---

## Step 1 — decide what "tag as escalate" means

This is the one design decision, and it drives everything else.

Planner Premium's coloured **labels** are a Planner-layer concept. They are *not* reliably a
first-class filterable column on `msdyn_projecttask`, so **do not build the trigger on the label**
unless the discovery script shows you a concrete label column you can filter on.

Three options, best first:

**Option A — a bucket called "Escalate" (recommended).**
Zero customisation, works today, trivially filterable, and it's visually obvious in the UI —
your colleague literally drags the card into the Escalate bucket.

**Option B — a custom Yes/No column on the task.**
Add `cr123_escalate` (Two Options) to `msdyn_projecttask`. Clean and precise, and Dataverse can
trigger directly on that column changing. Requires a small schema change to a Microsoft table.

**Option C — a naming convention**, e.g. prefix the card title with `[escalate]`.
Ugly, but needs no setup at all and `contains(msdyn_subject,'escalate')` just works.

Everything below uses **Option A**, with the Option B/C filters noted inline.

---

## Step 2 — get the two plan IDs

Run this once and save both GUIDs — you'll hardcode them in the flow.

```
GET https://orgXXXX.crm.dynamics.com/api/data/v9.2/msdyn_projects
      ?$select=msdyn_projectid,msdyn_subject
      &$filter=contains(msdyn_subject,'1:1')
```

You want:
- `SOURCE_PLAN_ID` — the colleague's 1:1s-with-their-team plan
- `TARGET_PLAN_ID` — their 1:1-with-manager plan

And the Escalate bucket in the source plan:

```
GET .../msdyn_projectbuckets
      ?$select=msdyn_projectbucketid,msdyn_subject
      &$filter=_msdyn_project_value eq SOURCE_PLAN_ID
```

---

## Step 3 — the flow

### Trigger: Dataverse → *When a row is added, modified or deleted*

| Setting | Value |
| --- | --- |
| Change type | **Added or Modified** |
| Table name | **Project Tasks** (`msdyn_projecttask`) |
| Scope | **Organization** |
| Select columns | `msdyn_subject,msdyn_projectbucket,msdyn_project,msdyn_description,msdyn_scheduledend` |
| Filter rows | `_msdyn_project_value eq SOURCE_PLAN_ID` |

Two things people get wrong here:

- **Scope must be `Organization`.** The default is `User`, and the flow owner does not own the
  Planner-created rows, so the trigger silently never fires.
- **Set `Select columns`.** Without it the trigger fires on *every* field change, including the
  scheduling-engine churn Project writes constantly. You'll burn through runs for nothing.

> **Verified gotcha — singular vs plural table name.** If you build this flow from JSON rather than
> the designer, the **trigger** takes the *singular logical name* (`msdyn_projecttask`) while the
> **actions** take the *plural entity set name* (`msdyn_projecttasks`). Getting this wrong fails at
> **save** time, not run time, with a misleading error:
> `GetMetadataForGetEntityCUDTrigger failed ... EntityNotFound ... Could not find table with name 'msdyn_projecttasks'`.
> The designer hides this; hand-authored JSON and ALM pipelines do not.


### Condition: is it escalated?

Add a **Condition**:

```
_msdyn_projectbucket_value  is equal to  ESCALATE_BUCKET_ID
```

> Option B instead: `cr123_escalate` **is equal to** `true`
> Option C instead: use `contains(toLower(triggerOutputs()?['body/msdyn_subject']),'escalate')` **is equal to** `true`

### Guard against duplicates

The trigger fires on *modify* too, so without this you'll create a new card every time the escalated
card is touched. In the **If yes** branch, first add **Dataverse → List rows**:

| Setting | Value |
| --- | --- |
| Table name | **Project Tasks** |
| Filter rows | `_msdyn_project_value eq TARGET_PLAN_ID and contains(msdyn_subject,'@{triggerOutputs()?['body/msdyn_subject']}')` |
| Row count | `1` |

Then a nested **Condition**:

```
length(outputs('List_rows')?['body/value'])   is equal to   0
```

Only create the copy in the **If yes** branch of *that*.

> More robust alternative: add a custom text column `cr123_sourcetaskid` to `msdyn_projecttask` and
> filter on `cr123_sourcetaskid eq '<guid>'`. Exact match, survives renames. Requires Option B-style
> schema change.

### Create the duplicate card

**You cannot use "Add a new row" for this.** This is the single most important thing in this
document, and it is not obvious until you try it.

`msdyn_projecttask` rows are owned by the Project Scheduling Service. A direct Dataverse create is
rejected at runtime with:

> `We're sorry. You cannot directly do 'Create' operation to 'msdyn_projecttask'. Try editing it through the Resource editing UI in Dynamics or via Project.`

The same applies to `msdyn_projectbucket`. (`msdyn_project` itself *can* be created directly.)
Verified against a real environment — a flow built with **Add a new row** saves happily and then
fails on every run.

The supported route is the **Project Schedule API**, using three *Perform an unbound action* steps:

| Step | Action | Key inputs |
| --- | --- | --- |
| 1. Create operation set | `msdyn_CreateOperationSetV1` | `Description`, `Project` = target plan id |
| 2. Queue the create | `msdyn_PssCreateV1` | `Entity` = task JSON, `OperationSetId` from step 1 |
| 3. Run it | `msdyn_ExecuteOperationSetV1` | `OperationSetId` from step 1 |

The `Entity` payload for step 2:

```json
{
  "@odata.type": "Microsoft.Dynamics.CRM.msdyn_projecttask",
  "msdyn_projecttaskid": "@{guid()}",
  "msdyn_subject": "@{triggerOutputs()?['body/msdyn_subject']}",
  "msdyn_project@odata.bind": "/msdyn_projects(TARGET_PLAN_ID)",
  "msdyn_projectbucket@odata.bind": "/msdyn_projectbuckets(TARGET_BUCKET_ID)",
  "cr123_escalatesourceid": "@{triggerOutputs()?['body/msdyn_projecttaskid']}",
  "msdyn_start": "@{utcNow()}",
  "msdyn_scheduledstart": "@{utcNow()}",
  "msdyn_scheduledend": "@{addDays(utcNow(),5)}",
  "msdyn_LinkStatus": 192350000
}
```

Points that matter:

- **You must generate the primary key yourself** with `guid()`. The Schedule API requires the id in
  the payload — it does not hand one back.
- Lookups still use **`@odata.bind`** with the entity-set path, not a bare GUID.
- Reads are *not* restricted — the dedupe **List rows** step uses the ordinary Dataverse action.


---

## Proven working — prototype results

The logic below is not theoretical. It was built and run end-to-end against mock tables that
mirror the Planner Premium schema (`Build-MockPlannerSchema.ps1` + `Seed-MockPlannerData.ps1`),
in a Dataverse environment where Project for the web is not installed.

Test results — 9 flow runs, all Succeeded, exactly 3 cards created:

| Test | Expected | Result |
| --- | --- | --- |
| Move card into Escalate bucket | 1 copy created | 1 copy |
| Move out, move back in, then rename | still 1 copy | still 1 copy |
| Escalate a second, different card | 2 copies | 2 copies |
| Set the `escalate` Yes/No flag (Option B) | 3 copies | 3 copies |

The dedupe guard is the part that matters: the trigger fired **9 times** but only **3** cards were
created. Without it you would have 9 duplicates in the manager's plan.

Note the flow also survives its own writes. Creating the copy fires the trigger again (same table,
Organization scope), but the copy lands in the target bucket with the flag unset, so the condition
is false and it stops. That is an accidental loop guard — see *Known gotchas* before you extend it.

---

## Step 4 — test it

1. In the source plan, drag a card into the **Escalate** bucket.
2. Flow run history → confirm one run, one created row.
3. Move the card out and back in → confirm **no second copy** (dedupe working).
4. Check the card appears in the manager 1:1 plan in the Planner UI.

Planner's Dataverse writes are not instant — allow up to ~60 seconds for the trigger to fire.

---

## Known gotchas

- **Licensing.** Reading/writing `msdyn_*` tables via Dataverse needs an appropriate Project plan
  for the flow's connection identity. A Power Automate licence alone is not enough. Use a service
  account with a Project Plan 3 / Planner Premium licence.
- **Check bundled service plans, not just SKU names.** The entitlement is often already present
  inside a bundle. Listing top-level SKU part numbers will show no "Project" SKU while
  `PROJECT_FOR_PROJECT_OPERATIONS` / `PROJECT_ESSENTIALS` sit inside another licence and are fully
  provisioned. Check with:
  `GET https://graph.microsoft.com/v1.0/subscribedSkus` then inspect each `servicePlans[]`.
  Getting this wrong leads to concluding the work is impossible when it isn't.
- **Installing the app is separate from holding the licence.** Entitlement does not provision the
  tables. `msdyn_project*` only appears after the Project app is installed into that specific
  environment. Install via PPAC, or the app-management API:
  `POST https://api.powerplatform.com/appmanagement/environments/{envId}/applicationPackages/{uniqueName}/install?api-version=2022-03-01-preview`
  Note the path takes the package **uniqueName** (e.g. `ProjectOperations_Anchor`) — passing the
  `applicationId` GUID returns `400 Package requested for installation was not found`.
- **Singular table name in the trigger, plural in the actions.** See the trigger section — this
  fails at save time with a confusing `EntityNotFound`.
- **Don't create the reverse sync** without a loop guard. The flow already triggers on its own
  writes (it's the same table at Organization scope) and only stops because the copy doesn't match
  the escalate condition. If you add "copy status back", that accident stops protecting you and the
  two flows will trigger each other indefinitely. Use an explicit `cr123_syncsource` marker column.
- **Scheduling engine churn.** `msdyn_projecttask` rows get rewritten by Project's scheduler far
  more often than a human edits them. Always constrain trigger columns.
- **Deletes.** Change type `Added or Modified` won't catch un-escalation. Add a separate flow on
  `Deleted`, or handle the bucket-moved-out case explicitly, if that matters.
- **Latency.** Allow ~30-60 seconds between the change and the copy appearing.

---

## What is and isn't proven

Being precise about this, because the difference matters.

**Verified against a real environment with the genuine `msdyn_project*` tables:**

- The schema — table names, entity set names, column names, lookup navigation properties. Taken
  from live metadata, not documentation.
- `msdyn_projecttask` and `msdyn_projectbucket` **reject direct creates**. Reproduced, with the
  exact error text quoted above. `msdyn_project` does not.
- Bucket display name is **`msdyn_name`**, while plan and task use `msdyn_subject`.
- There is **no label/tag column** on `msdyn_projecttask`, which settles the bucket-vs-label design
  question — a label-driven trigger has nothing to filter on.
- The solution ZIP **imports cleanly**, and the flow arrives with the correct trigger, name-based
  conditions, target lookups, guard and Schedule API steps.

**Verified only against mock tables** (a prototype mirroring the schema, 9 runs, 3 cards created):

- The trigger fires on the bucket move.
- The dedupe guard holds — repeated edits and re-escalation do not create extra copies.
- The flow does not loop on its own writes.

**Not verified:**

- The three Schedule API calls have **not been executed**. The environment used for schema
  discovery had only a partial Project install, so `msdyn_CreateOperationSetV1`, `msdyn_PssCreateV1`
  and `msdyn_ExecuteOperationSetV1` were absent. Their shape follows Microsoft's documented
  walkthrough, but the first real run is yours.
- That `msdyn_projectname` and `msdyn_projectbucketname` are populated in the **trigger** payload.
  They exist on the table and Dataverse populates lookup name columns as standard, but the
  name-based condition depends on it. If the flow never fires on a genuine escalation, this is the
  first thing to check — swap the condition to `_msdyn_projectbucket_value` against the bucket GUID.
- Whether Planner Premium adds columns beyond what Project Operations installs.

**So on first run, watch for:** the operation set executing but the task not appearing (usually a
bad `@odata.bind` path), or `msdyn_LinkStatus` being rejected. Check the flow run history — the
`Execute_operation_set` step returns the failure detail.


## Scripts

| Script | Purpose |
| --- | --- |
| `Build-DistributableSolution.ps1` | **Main script.** Builds the whole solution, exports it, injects the Schedule API definition, repacks and verifies. `-ImportTest` also proves it imports. |
| `Discover-PlannerPremiumSchema.ps1` | Dump real table/column/lookup names from an environment that has Project for the web |
| `Test-EscalateSolution.ps1` | Seed plans/buckets/cards for an end-to-end test |
| `Build-MockPlannerSchema.ps1` | Create mock tables mirroring the schema, for environments without Project |
| `Seed-MockPlannerData.ps1` | Seed the mock two-plan 1:1 scenario |

All take `-OrgUrl` and are idempotent. Pass `-WorkDir` and `-OutZip` explicitly — `$PSScriptRoot`
does not resolve in a param block when the script is launched via `powershell -File`.

Three packaging traps the build script guards against, all of which broke a real import first:

- **No BOM.** `Set-Content -Encoding UTF8` on Windows PowerShell writes a UTF-8 BOM. Import then
  fails with `Flow clientdata is in invalid format ... Unexpected character encountered while
  parsing value`. Use `[IO.File]::WriteAllText` with `UTF8Encoding($false)`.
- **Forward slashes in ZIP entries.** `ZipFile::CreateFromDirectory` writes backslashes on .NET
  Framework, which is invalid per the ZIP spec. Add entries manually.
- **Ordering when replacing environment variables.** A variable still referenced by a flow cannot
  be deleted. Reset the flow to a placeholder first, then delete, then recreate.



