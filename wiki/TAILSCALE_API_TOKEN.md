# Tailscale API token

You can create the token here:
[https://login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys).

Under **API access tokens**, click **Generate access token\u2026**.
90 days is the maximum, and the description can be anything,
e.g. `born2root baas`.

For a credential that never expires, use an OAuth client instead:
[https://login.tailscale.com/admin/settings/oauth](https://login.tailscale.com/admin/settings/oauth),
with scopes `auth_keys`, `dns` and `devices`.

**Do not paste the token in chat or issues.**
Anything sent in conversation history stays there.
Write it straight into the secrets file instead
(only needs to be done once):

```bash
nano ~/.config/born2root/b2b-secrets
```

Fill in the empty `TS_API_TOKEN=` line, or add one if
it's missing:

```text
TS_API_TOKEN=tskey-api-...
```
