# mostlymatter-oidc

[Mostlymatter](https://framagit.org/framasoft/framateam/mostlymatter) server
binaries with an OpenID Connect login provider. The patch registers a provider
for the `openid` service and exposes the OpenID login button in the client
configuration. The stock `mattermost/mattermost-team-edition` webapp and
mobile apps then show the button without a license.

## Credits

This project is a small addition on top of other people's work:

- [Mattermost](https://github.com/mattermost/mattermost), by Mattermost, Inc.
  and its contributors, is the server, webapp and mobile apps. Its open source
  server under AGPL-3.0 makes a patch like this possible.
- [Mostlymatter](https://framagit.org/framasoft/framateam/mostlymatter), by
  [Framasoft](https://framasoft.org), lifts the server's user and message
  limits and follows every Mattermost release. We build on their
  `-limitless` tags and `limitless.patch`, and our release tags follow their
  scheme.

Thank you both. If you run Mattermost at scale or need its commercial
features, consider [Mattermost's own plans](https://mattermost.com/pricing/);
if Mostlymatter is useful to you, consider
[supporting Framasoft](https://soutenir.framasoft.org/en/).

## No guarantees

We aim to keep the builds automated and to follow upstream releases for as
long as we run Mattermost with Keycloak login ourselves, on a best-effort
basis. The patches and binaries come with absolutely no warranty or guarantee
of any kind, including that they work, are secure, or keep up with Mattermost
and Mostlymatter (AGPL-3.0 sections 15 and 16). Test a release before you
deploy it; you use it at your own risk.

## Build

```sh
BUILD_NUMBER=1 ./build.sh 12.0.2
```

`build.sh` checks out the Mostlymatter `v<version>-limitless` tag, or the
upstream Mattermost tag plus the newest `limitless.patch` of that minor
release. It applies `patches/openid.patch` and the version's
`patches/openid-get-user-*.patch`, then builds `dist/mostlymatter-amd64-v<version>`
with its `.sha512`, a `.source` line naming the upstream source, and
Mattermost's `NOTICE.txt`. It needs the Go version from `server/.go-version`.

## Supported versions

`versions.json` lists one entry per release line: `line` is the version
prefix the line follows (`12` follows every 12.x release), `version` the
release built, and `image` the digest-pinned `mattermost-team-edition` image it
is tested in.

`.github/workflows/build.yml` builds and tests every entry on pull requests
and pushes to `main`. `test/e2e.sh <version>` runs the binary from `dist/` in
its image against Postgres and Keycloak: it logs a new user in twice and runs
the account migration from `MIGRATE-FROM-GITLAB.md` on a GitLab SSO account
with posts. On `main` the workflow then releases each listed version that has
no release yet as `v<version>-oidc`, with its binary, sha512, `LICENSE` and
Mattermost's `NOTICE.txt`; the release notes name the upstream source. A
change to `patches/` or `build.sh` ships with the next version of each line.

`.github/workflows/track.yml` runs `track.sh` daily. It moves each line to
its newest upstream release that `build.sh` can build and that has a
team-edition image, then opens a pull request and starts the build and test
run on it.

To support another line, such as a new ESR, add an entry with its `line`,
current `version` and `image` to `versions.json`. If a new major version
changes the provider interface, add a `patches/openid-get-user-*.patch` for it
and select it in `build.sh`.

## Run

A release replaces the server binary only. The webapp and everything else come
from Mattermost's official `mattermost/mattermost-team-edition` image, unchanged.
Build an image on top of that image, of the same version, with the release
binary in place of its server binary:

```dockerfile
FROM mattermost/mattermost-team-edition:12.0.2
COPY --chmod=755 mostlymatter-amd64-v12.0.2 /mattermost/bin/mattermost
```

## Configure

Keycloak: create a confidential OpenID Connect client with the standard flow
and these redirect URIs:

- `<SiteURL>/signup/openid/complete`
- `<SiteURL>/login/openid/complete`

Users need a verified email address and a username; Mattermost takes their
first and last names from Keycloak.

Without a license, Mattermost shows the OpenID button on the login page but
not on the signup page that invitation links open. A new user logs in on the
login page, which creates the account, and then opens the invitation link to
join the team.

Mattermost hides the OpenID page of the System Console without a license, so
configure the provider through the environment or `config.json`:

```sh
MM_OPENIDSETTINGS_ENABLE=true
MM_OPENIDSETTINGS_ID=mattermost
MM_OPENIDSETTINGS_SECRET=<client secret>
MM_OPENIDSETTINGS_AUTHENDPOINT=https://<keycloak>/realms/<realm>/protocol/openid-connect/auth
MM_OPENIDSETTINGS_TOKENENDPOINT=https://<keycloak>/realms/<realm>/protocol/openid-connect/token
MM_OPENIDSETTINGS_USERAPIENDPOINT=https://<keycloak>/realms/<realm>/protocol/openid-connect/userinfo
MM_OPENIDSETTINGS_BUTTONTEXT=Keycloak
```

The provider does not read `DiscoveryEndpoint`, so set the three endpoints.
The scope defaults to `profile openid email`. When the Keycloak host resolves
to a private address, add it to
`MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS`.

The provider reads the userinfo response: `sub` becomes the account's auth
data, `email` (required, with `email_verified` true) the email address,
`preferred_username` up to any `@` the username, and `given_name` and
`family_name` the names.

## Move GitLab SSO accounts to OpenID

Accounts created through GitLab SSO need a one-time switch to the OpenID
provider before their users can log in with it; see
[MIGRATE-FROM-GITLAB.md](MIGRATE-FROM-GITLAB.md).

## License

AGPL-3.0, the license of the Mattermost server source; see `LICENSE`. Anyone
offering this server over a network must offer its users the source code,
for example with a link to this repository on the login page: set
`TeamSettings.EnableCustomBrand` to `true` and put the link in
`TeamSettings.CustomBrandText`, which the login page shows as Markdown.

The binaries are a modified version of Mostlymatter. d-centralize B.V.
modifies it with the patches in `patches/`, first on 2026-11-05; their git
history dates each change. `openid.patch` adds the package
`server/channels/app/oauthproviders/openid` and changes
`server/cmd/mostlymatter/main.go` and `server/config/client.go`;
`openid-get-user-*.patch` adds `get_user.go` to that package. The source code
of release `v<version>-oidc` is this repository at that tag
together with the Mattermost and Mostlymatter sources its release notes name.

The binaries contain no Mattermost enterprise code. `build.sh` refuses
`BUILD_NUMBER=dev`, because the Mattermost Makefile then adds the
`sourceavailable` build tag, which compiles `server/enterprise` (Mattermost
Source Available License) into the binary.

Mattermost is a trademark of Mattermost, Inc. This project is not affiliated
with Mattermost, Inc. or Framasoft.
