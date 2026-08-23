# Contributing

Contributions are welcome, particularly **verification results**. Several behaviours here are
documented as unverified, and a confirmation or correction from a real Planner Premium environment is
the single most valuable contribution possible.

## Especially useful

- **Schedule API results.** The three Project Schedule API calls have never been executed against a
  full Project install. If you run them, say what happened.
- **Trigger payload contents.** Whether `msdyn_projectname` and `msdyn_projectbucketname` are
  populated in the trigger payload decides whether name-based conditions work at all.
- **Additional tables or columns.** If Planner Premium adds anything beyond what Project Operations
  installs, the schema reference should say so.
- **Other automation patterns.** This repo covers one worked example. If you build a different
  Planner Premium automation and hit a pattern worth writing down, add it to
  `docs/automation-patterns.md`.
- **Connectivity check gaps.** If an environment fails in a way the check does not detect or
  explain, that is a bug worth reporting.

## Reporting a result

Open an issue using the **Verification result** template. Redact your org URL, tenant ID and any
GUIDs before posting.

## Raising a bug

Include the flow run history detail for the failing step. `Execute_operation_set` returns the
underlying failure reason, which is almost always the useful part.

## Pull requests

1. Keep changes focused, one concern per PR.
2. PowerShell scripts must stay idempotent and take `-OrgUrl` as a mandatory parameter.
3. Keep the repo **generic**. The worked example exists to prove the patterns; new material should
   go in the patterns or table reference rather than deepening the example.
4. Never commit an org URL, tenant ID, connection ID, token or `.snk` file.
5. If you repack the solution zip, use forward slashes in entry paths. `Compress-Archive` on Windows
   PowerShell writes backslashes, which is not what the original uses.
6. Update the README if you change behaviour, and be explicit about what you verified versus what you
   assumed.

## Code of conduct

Be constructive and assume good faith.
