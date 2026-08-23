# Worked example - setup guide

**What this does:** when you drag a card into a bucket called **Escalate** in the source plan,
a copy of that card automatically appears in the target plan.

You do **not** need to edit or understand the automation. You type in four plan and bucket names,
switch it on, and it runs.

Setup takes about 10 minutes.

---

## Before you start

You need:
- **Microsoft Planner with a Premium plan licence** (Project Plan 3 / Planner Premium). The
  automation reads Premium plan data, which ordinary Planner plans don't have.
- Permission to import a solution into your environment. If you don't have it, your Power Platform
  admin does - send them this guide.

> **Which environment?** Import into the environment your Planner Premium data lives in, which is
> almost always your organisation's **default** environment. This matters: the automation has to sit
> in the same environment as the data, because Power Automate cannot watch for changes in a
> different one. If you import it somewhere else it will install fine and simply never run.

---

## Step 1 - Create your buckets in Planner

Do this first, in Planner itself, before importing anything.

In your **source plan**, create a bucket named exactly:

```
Escalate
```

In your **target plan**, create a bucket named exactly:

```
Escalated from team
```

You can use different names - just note down exactly what you typed, including capital letters and
spacing, because you'll enter them in Step 3.

> Buckets have to be made by hand here. Planner Premium doesn't allow buckets to be created
> automatically, so this step can't be done for you.

---

## Step 2 - Import the solution

1. Go to **make.powerapps.com** and check the environment name shown in the top right is the one
   you want (see the note above).
2. In the left menu select **Solutions**.
3. Select **Import solution** near the top.
4. Select **Browse**, choose `PlannerPremiumEscalate_2_0_0_0.zip`, then select **Next**.
5. When asked for a connection, pick your existing **Microsoft Dataverse** connection, or select
   **New connection**, sign in, and come back to this screen.
6. Select **Next**.

Don't select Import yet - the next screen is where you configure it.

---

## Step 3 - Fill in your four names

The import screen asks for four values. These are plain text - type the names exactly as they
appear in Planner.

| Setting | What to type | Example |
| --- | --- | --- |
| **Watch this plan** | The plan holding the source cards | `Team backlog` |
| **Escalate bucket** | The bucket that means "escalate this" | `Escalate` |
| **Copy into this plan** | Your target plan | `Escalations` |
| **Bucket for copies** | Where copies should land in that plan | `Escalated from team` |

**Names must match exactly** - capitals, spaces and punctuation all count. `Escalate` and
`escalate ` (with a trailing space) are different.

Now select **Import**. It usually takes 1-3 minutes.

---

## Step 4 - Turn it on

The automation is deliberately installed **switched off**, so nothing happens until you've checked
your settings.

1. Open **Solutions** and select **Planner Premium - Copy card to another plan**.
2. Select **Cloud flows**.
3. Open **Copy card to another plan**.
4. Select **Turn on**.

---

## Step 5 - Test it

1. In the source plan, drag any card into the **Escalate** bucket.
2. Wait about a minute.
3. Open the target plan. The card should be there.

Then check it doesn't duplicate: drag the same card out of **Escalate** and back in again. You
should still have only **one** copy in the target plan.

---

## If something doesn't work

**Nothing appears after a few minutes.**
Open the flow (Step 4) and look at **28-day run history** at the bottom.
- *No runs at all* - the automation isn't seeing your plan. Most likely it's installed in a
  different environment from your Planner data. Check the environment name in the top right.
- *A run shows "Failed" with a message about names* - one of your four names doesn't match. The
  error message names which one. Fix it in **Solutions → … → Environment variables**, then retry.
- *Runs show "Succeeded" but no card appears* - the copy was created in a different plan than you
  expected. Check **Copy into this plan** and **Bucket for copies**.

**Cards appear twice.**
Shouldn't happen - the automation records where each copy came from. If it does, check you haven't
imported the solution twice, or turned on two copies of the flow.

**I want to change a name later.**
Go to **Solutions → Planner Premium - Copy card to another plan → Environment variables**, select the
one you want, and update its **Current Value**. No need to touch the flow.

**I want to stop it.**
Open the flow and select **Turn off**. Cards already copied stay where they are.

---

## What it does and doesn't do

**Does:**
- Copies the card **title** into the target plan
- Adds a note recording the date and the card it came from
- Copies each card only once, no matter how often you edit or re-escalate it

**Doesn't:**
- Copy checklists, attachments, assignees, comments or due dates
- Keep the two cards in sync - later edits to the original don't update the copy
- Remove the copy if you drag the card back out of **Escalate**

**Privacy note:** the card title is copied into a plan other people can see. If a title contains
something you wouldn't want shared, rename it before escalating.
