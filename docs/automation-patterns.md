# Automation patterns

Patterns that apply to any Planner Premium automation, regardless of what the process actually does.

The worked example in this repo copies a card between plans. Yours might assign work when a card
enters a bucket, raise a ticket when a due date passes, or roll status up to another system. The
mechanics below are the same either way.

---

## 1. Decide what the trigger condition is

Every Planner Premium automation starts with "when does this fire?". There are three practical
options, and the choice drives everything else.

**A bucket, in most cases.** Zero customisation, trivially filterable, and visually obvious to the
user because they physically drag the card. Filter on `_msdyn_projectbucket_value`, or on the bucket
name if it is populated in the trigger payload.

**A custom column** when you need precision. Add a Two Options column such as `cr123_approved` to
`msdyn_projecttask`. Clean, and Dataverse can trigger directly on that column changing. Requires a
schema change to a Microsoft table, which some organisations restrict.

**A naming convention** as a last resort, for example a title prefix. Needs no setup at all and
`contains(msdyn_subject,'...')` just works. Ugly, and users will get the casing wrong.

> **Not labels.** Planner's coloured labels are a Planner-layer concept. There is no label or tag
> column on `msdyn_projecttask`, verified against live metadata, so a label-driven trigger has
> nothing to filter on. This is the single most common false start.

## 2. Constrain the trigger

`msdyn_projecttask` rows are rewritten by Project's scheduling engine far more often than a human
edits them. An unconstrained trigger fires constantly and burns API calls.

Always set:

- **Change type** appropriate to the process. `Added or Modified` will not catch a removal, so if
  un-doing matters, add a separate flow on `Deleted` or handle the moved-out case explicitly.
- **Filter columns**, so the trigger only fires when the columns you care about change.
- **Scope**, usually Organization, so it sees changes made by anyone.

**Singular table name in the trigger, plural in the actions.** The trigger takes the logical name
(`msdyn_projecttask`), actions take the entity set (`msdyn_projecttasks`). Getting this wrong fails
at save time with a confusing `EntityNotFound`.

## 3. Guard against duplicates

This is the pattern that separates a working automation from one that quietly makes a mess.

A trigger fires on **every** qualifying change, not once per card. A user who drags a card out and
back in, or renames it afterwards, fires it again. Without a guard you get a duplicate for every
fire.

**Record the origin.** When the automation acts on a card, write the source record id somewhere the
next run can check, then check for it before acting.

```
1. Trigger fires
2. Does a record already exist with sourceId = this card's id?
      yes -> stop
      no  -> proceed
3. Act, writing sourceId onto whatever you create
```

In the worked example, the trigger fired **9 times** and created exactly **3** records. Without the
guard that would have been 9.

Where to keep the marker:

| Option | Use when |
|---|---|
| A custom column on the created record | You control the target table |
| A custom column on the source card | The target is an external system |
| A separate tracking table | Many-to-many, or you need an audit trail |

## 4. Guard against loops

If your automation **writes to the same table it triggers on**, it will fire itself. At Organization
scope it cannot tell its own writes from anyone else's.

The worked example survives this by accident: the record it creates does not match the trigger
condition, so the second fire stops at the condition check. That is an accidental guard, and it
stops protecting you the moment you extend the flow.

If you add anything that writes back, use an **explicit marker column**, for example
`cr123_syncsource`, and exclude marked rows in the trigger filter. Do not rely on the condition
happening not to match.

Two flows that write to each other's tables will trigger each other indefinitely. Design for that
before you build the second flow, not after.

## 5. Configuration, not hardcoding

Plan and bucket GUIDs differ per environment. Hardcoding them means the solution only works where it
was built, and the person who inherits it cannot change anything without opening the flow.

Use **environment variables** for anything environment-specific:

- Plan names or ids
- Bucket names or ids
- Thresholds, target addresses, external system endpoints

Set at import time, changeable afterwards through **Solutions → Environment variables** without
touching the flow. This is what makes a solution handover-ready rather than a personal script.

**Ship the flow disabled.** Nothing should run until whoever imported it has checked the
configuration. Turning it on is a deliberate act.

## 6. Name-based versus id-based matching

Matching on names is friendlier to configure and more fragile at runtime. Matching on GUIDs is the
reverse.

| | Names | GUIDs |
|---|---|---|
| Configure | Readable, typo-prone | Opaque, exact |
| Runtime | Breaks if renamed | Stable |
| Portability | Works across environments | Environment-specific |

A reasonable middle path: accept **names** as environment variables, resolve them to ids once at the
start of the run, and fail loudly with a clear message if a name does not resolve. The user gets a
readable configuration and a useful error rather than silence.

## 7. Creating tasks needs the Schedule API

`msdyn_projecttask` and `msdyn_projectbucket` **reject direct creates**. Tasks must be created
through three unbound actions in sequence:

```
msdyn_CreateOperationSetV1     open an operation set
msdyn_PssCreateV1              stage the create
msdyn_ExecuteOperationSetV1    commit
```

Updates to existing tasks work normally. **If your automation only modifies cards, you never touch
the Schedule API**, and the build is dramatically simpler. Check whether you actually need to create
before designing around it.

When a Schedule API run fails, the detail is in the `Execute_operation_set` step output, not the
step that appears to have failed.

## 8. Fail loudly on configuration errors

A flow that silently does nothing is the worst outcome, because nobody notices for weeks.

If a configured plan or bucket name does not resolve, **terminate with a message naming the setting
that is wrong**. The run history then tells the owner exactly what to fix, rather than showing a
successful run that did nothing.

## 9. Test the negative cases

For any Planner Premium automation, these four tests catch most defects:

| Test | Expected |
|---|---|
| Perform the triggering action once | Acts exactly once |
| Undo it and redo it | Still one result, not two |
| Edit the card afterwards | No additional result |
| Perform it on a second card | Two results total |

The second and third are where naive implementations fall over.

## 10. Rehearse without a licence

You do not need Planner Premium licences to validate the *pattern*. The mock schema mirrors the real
table shape closely enough to prove trigger, condition, dedupe and loop behaviour:

```powershell
.\scripts\Build-MockPlannerSchema.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
.\scripts\Seed-MockPlannerData.ps1   -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
```

The one behaviour it cannot reproduce is the create restriction: mock tables accept direct creates,
real task and bucket tables do not. Validate the Schedule API path against a real environment before
depending on it.

---

## Retrofitting the worked example

The example solution in `solution/` copies a card from one plan to another when it lands in a named
bucket. To adapt it:

| To change | Where |
|---|---|
| Which plan and bucket trigger it | Environment variables, set at import |
| What condition fires it | The condition step, using section 1 above |
| What the automation does | Replace the create step; the trigger, condition and guard stay |
| Where the dedupe marker lives | The guard step, using section 3 |

The trigger, condition, dedupe guard and configuration pattern carry over unchanged. In most cases
only the action in the middle is genuinely specific to your process.
