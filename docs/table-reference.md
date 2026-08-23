# Planner Premium table reference

What Planner Premium looks like in Dataverse, and which tables and columns you need for any
automation against it.

Taken from live metadata, not documentation.

---

## The mapping

| Planner Premium UI | Dataverse table | Entity set (use in URLs) |
|---|---|---|
| Plan | `msdyn_project` | `msdyn_projects` |
| Card / Task | `msdyn_projecttask` | `msdyn_projecttasks` |
| Bucket | `msdyn_projectbucket` | `msdyn_projectbuckets` |
| Assignment (who is on the card) | `msdyn_resourceassignment` | `msdyn_resourceassignments` |
| Plan membership | `msdyn_projectteam` | `msdyn_projectteams` |

**Planner Premium plans are Project for the web plans.** They are not Group-backed Planner plans, and
the `shared_planner` connector cannot see them. Everything below is reached with the **Microsoft
Dataverse** connector.

## Naming inconsistency that costs people time

| Table | Display name column |
|---|---|
| `msdyn_project` | `msdyn_subject` |
| `msdyn_projecttask` | `msdyn_subject` |
| `msdyn_projectbucket` | **`msdyn_name`** |

Plans and tasks use `msdyn_subject`. Buckets use `msdyn_name`. There is no `name` column on a task
and no `subject` column on a bucket, and the error you get is not obvious.

## Which environment

**The tenant DEFAULT environment.** Planner Premium writes there and nowhere else.

```powershell
pac org list
```

If you point at a dev environment you get zero rows and no error, which is the usual dead end. Run
the connectivity check before anything else:

```powershell
.\scripts\Test-PlannerPremiumConnectivity.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
```

## Discovering the columns for yourself

Column sets differ between tenants, because Planner Premium may add columns beyond what Project
Operations installs. Do not trust a column list from a blog post, including this one. Dump your own:

```powershell
.\scripts\Discover-PlannerPremiumSchema.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
```

Or the summary form:

```powershell
.\scripts\Test-PlannerPremiumConnectivity.ps1 -OrgUrl https://... -Detailed
```

---

## Common query shapes

### Plans

```http
GET /api/data/v9.2/msdyn_projects
      ?$select=msdyn_projectid,msdyn_subject
      &$filter=contains(msdyn_subject,'Onboarding')
```

### Buckets in a plan

```http
GET /api/data/v9.2/msdyn_projectbuckets
      ?$select=msdyn_projectbucketid,msdyn_name
      &$filter=_msdyn_project_value eq <planId>
```

### Tasks in a bucket

```http
GET /api/data/v9.2/msdyn_projecttasks
      ?$select=msdyn_projecttaskid,msdyn_subject
      &$filter=_msdyn_projectbucket_value eq <bucketId>
```

Lookup columns are queried as `_<name>_value` and written as `<NavigationProperty>@odata.bind`. The
navigation property is **not** always the column name. Get the real ones from the discovery script.

---

## What you can and cannot write

Verified against real `msdyn_project*` tables:

| Table | Direct create via Dataverse connector |
|---|---|
| `msdyn_project` | Allowed |
| `msdyn_projecttask` | **Rejected** |
| `msdyn_projectbucket` | **Rejected** |

Tasks and buckets must be created through the **Project Schedule API**, a sequence of three unbound
actions:

```
msdyn_CreateOperationSetV1     open an operation set
msdyn_PssCreateV1              stage the create
msdyn_ExecuteOperationSetV1    commit
```

These only exist where Project is fully installed. The connectivity check reports whether they are
present.

**Updates to existing tasks work normally** through the Dataverse connector. If your automation only
needs to modify cards rather than create them, you can skip the Schedule API entirely, which is a
much simpler build.

---

## Trigger constraints

**Triggers cannot fire on changes in another environment.** Actions ending in *"from selected
environment"* can read across environments; triggers cannot. A flow in a dev environment pointed at
the default environment will import cleanly and never run.

Install the flow in the same environment as the data, or fall back to a **Recurrence + List rows**
polling loop, which costs latency and API calls.

**Constrain the trigger columns.** `msdyn_projecttask` rows are rewritten by Project's scheduling
engine far more often than a human edits them. An unconstrained trigger will fire constantly.

**Latency is 30 to 60 seconds** between a change in the Planner UI and the trigger firing. Do not
design a UI that implies it is instant.

---

## Licensing

Reading and writing `msdyn_*` tables needs a Project Plan 3 or Planner Premium licence **on the
identity the flow runs as**. A Power Automate licence alone is not enough.

**Check bundled service plans, not SKU names.** The entitlement is often already present inside
another licence:

```http
GET https://graph.microsoft.com/v1.0/subscribedSkus
```

Inspect each `servicePlans[]` for `PROJECT_FOR_PROJECT_OPERATIONS` or `PROJECT_ESSENTIALS`. Listing
top-level SKU part numbers will show no "Project" SKU while the entitlement sits inside a bundle and
is fully provisioned. Getting this wrong leads people to conclude the work is impossible when it is
not.

**Entitlement is separate from provisioning.** The tables only appear after the Project app is
installed into that specific environment. Install through the admin centre, or:

```http
POST https://api.powerplatform.com/appmanagement/environments/{envId}/applicationPackages/{uniqueName}/install?api-version=2022-03-01-preview
```

The path takes the package **uniqueName**, for example `ProjectOperations_Anchor`. Passing the
`applicationId` GUID returns `400 Package requested for installation was not found`.

---

## Testing without a Premium licence

The repo ships a mock schema that mirrors the real table shape, so you can build and test an
automation pattern before you have licences or a provisioned environment:

```powershell
.\scripts\Build-MockPlannerSchema.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
.\scripts\Seed-MockPlannerData.ps1   -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
.\scripts\Test-PlannerPremiumConnectivity.ps1 -OrgUrl https://... -MockPrefix cra89
```

The mock tables accept direct creates, which the real task and bucket tables do not. That is the one
behaviour the mock cannot reproduce, so validate the Schedule API path against a real environment
before relying on it.
