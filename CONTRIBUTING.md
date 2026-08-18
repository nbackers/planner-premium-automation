# Contributing

Contributions are welcome — particularly **verification results**. Several behaviours in this repo
are documented as unproven (see the "What is and isn't proven" section of the README), and a
confirmation or correction from a real Planner Premium environment is the single most valuable
contribution possible here.

## Reporting a result

If you run this against a genuine Project for the web install, please open an issue stating:

- Whether the three Project Schedule API calls succeeded
- Whether `msdyn_projectname` / `msdyn_projectbucketname` were populated in the trigger payload
- Your environment type and Project licence

Redact your org URL, tenant ID and any GUIDs before posting.

## Raising a bug

Include the flow run history detail for the failing step. `Execute_operation_set` returns the
underlying failure reason, which is almost always the useful part.

## Pull requests

1. Keep changes focused — one concern per PR.
2. PowerShell scripts must stay idempotent and take `-OrgUrl` as a mandatory parameter.
3. Never commit an org URL, tenant ID, connection ID, token or `.snk` file. Run the pre-publish
   scan before pushing.
4. Update the README if you change behaviour, and be explicit about what you verified versus what
   you assumed.

## Code of conduct

Be constructive and assume good faith.
