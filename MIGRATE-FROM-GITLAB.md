# Move GitLab SSO accounts to OpenID

A user logs in to an existing account only when its auth service and auth
data match the provider. Accounts created through GitLab SSO keep the GitLab
user id, so switch them to the Keycloak `sub` once, matched by email.

Export the Keycloak users as `email,id` lines. Users without an email
address, such as service accounts, export with an empty email and match no
account.

```sh
kcadm.sh get users -r <realm> --limit 100000 --fields email,id --format csv --noquotes > kc_users.csv
```

Stop Mattermost, then run this with `psql` in the directory that holds
`kc_users.csv`:

```sql
BEGIN;
CREATE TEMP TABLE kc_users (email text, sub text NOT NULL) ON COMMIT DROP;
\copy kc_users FROM 'kc_users.csv' WITH (FORMAT csv)
UPDATE users u
SET authservice = 'openid', authdata = k.sub, updateat = (extract(epoch FROM now()) * 1000)::bigint
FROM kc_users k
WHERE u.authservice = 'gitlab' AND lower(u.email) = lower(k.email);
SELECT username, email FROM users WHERE authservice = 'gitlab';
COMMIT;
```

The final query lists the GitLab accounts without a Keycloak match. A migrated
account logs in through OpenID only; the GitLab button no longer works for it.
