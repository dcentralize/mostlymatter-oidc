#!/usr/bin/env bash
# End-to-end test of dist/mostlymatter-amd64-v<version> in the team-edition
# image from versions.json: Keycloak login, and the GitLab-to-OpenID migration
# exactly as MIGRATE-FROM-GITLAB.md documents it.
# Usage: test/e2e.sh <version>   (set DOCKER="sudo docker" if needed)
set -euo pipefail

version=${1:?usage: $0 <version>}
repo=$(cd "$(dirname "$0")/.." && pwd)
binary=$repo/dist/mostlymatter-amd64-v$version
image=$(jq -r --arg v "$version" '.[] | select(.version == $v) | .image' "$repo/versions.json")
if [ -z "$image" ]; then
  echo "$version is not in versions.json" >&2
  exit 1
fi
keycloak=quay.io/keycloak/keycloak:26.8.1@sha256:3f3c5f8e03c614774b4bd9173b88391fefa4153bfc010d8012d59ad825377332
postgres=postgres:16.15-alpine@sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab
read -ra docker <<<"${DOCKER:-docker}"
net=mmoidc-e2e
mm=http://mm:8065
kc=http://keycloak:8080/realms/test/protocol/openid-connect
connect=(--connect-to keycloak:8080:127.0.0.1:28080 --connect-to mm:8065:127.0.0.1:28065)
json='Content-Type: application/json'
xhr='X-Requested-With: XMLHttpRequest'

remove() {
  "${docker[@]}" rm -f mmoidc-mm mmoidc-pg mmoidc-kc >/dev/null 2>&1 || true
  "${docker[@]}" network rm "$net" >/dev/null 2>&1 || true
}
remove
work=$(mktemp -d)
trap 'remove; rm -rf "$work"' EXIT

c() { curl -s "${connect[@]}" "$@"; }
wait_for() {
  local i
  for i in $(seq 180); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "timed out: $*" >&2
  return 1
}
check() {
  local what=$1
  shift
  if "$@"; then
    echo "ok: $what"
  else
    echo "FAIL: $what" >&2
    "${docker[@]}" logs mmoidc-mm 2>&1 | grep '"level":"error"' | tail -n 5 >&2 || true
    exit 1
  fi
}
psql() { "${docker[@]}" exec -i mmoidc-pg psql -U mmuser -d mm -v ON_ERROR_STOP=1 -At "$@"; }
token() {
  c -D - -o /dev/null -H "$json" -d "{\"login_id\":\"$1\",\"password\":\"$2\"}" $mm/api/v4/users/login |
    awk 'tolower($1) == "token:" { print $2 }' | tr -d '\r'
}
# Logs in through Keycloak with a fresh cookie jar and prints the HTTP status
# of the final redirect back to Mattermost.
oidc_login() {
  local jar=$work/$3 loc action back
  loc=$(c -o /dev/null -w '%{redirect_url}' -c "$jar" -b "$jar" $mm/oauth/openid/login)
  action=$(c -c "$jar" -b "$jar" "$loc" | grep -o 'action="[^"]*"' | head -n 1 |
    sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
  back=$(c -o /dev/null -w '%{redirect_url}' -c "$jar" -b "$jar" \
    --data-urlencode "username=$1" --data-urlencode "password=$2" "$action")
  c -o /dev/null -w '%{http_code}' -c "$jar" -b "$jar" "$back"
}
session() { c -b "$work/$1" -H "$xhr" "$mm/api/v4/$2"; }
mm_ready() { c -f -o /dev/null $mm/api/v4/system/ping; }

"${docker[@]}" network create "$net" >/dev/null
"${docker[@]}" run -d --name mmoidc-kc --network "$net" --network-alias keycloak -p 127.0.0.1:28080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -v "$repo/test/realm.json:/opt/keycloak/data/import/realm.json:ro" \
  "$keycloak" start-dev --import-realm >/dev/null
"${docker[@]}" run -d --name mmoidc-pg --network "$net" --network-alias db \
  -e POSTGRES_USER=mmuser -e POSTGRES_PASSWORD=mmpw -e POSTGRES_DB=mm "$postgres" >/dev/null
wait_for "${docker[@]}" exec mmoidc-pg pg_isready -h 127.0.0.1 -U mmuser -d mm
"${docker[@]}" run -d --name mmoidc-mm --network "$net" --network-alias mm -p 127.0.0.1:28065:8065 \
  -v "$binary:/mattermost/bin/mattermost:ro" \
  -e MM_SQLSETTINGS_DRIVERNAME=postgres \
  -e MM_SQLSETTINGS_DATASOURCE="postgres://mmuser:mmpw@db:5432/mm?sslmode=disable" \
  -e MM_SERVICESETTINGS_SITEURL=$mm \
  -e MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS=keycloak \
  -e MM_PLUGINSETTINGS_ENABLE=false \
  -e MM_OPENIDSETTINGS_ENABLE=true \
  -e MM_OPENIDSETTINGS_ID=mattermost \
  -e MM_OPENIDSETTINGS_SECRET=mm-test-secret \
  -e MM_OPENIDSETTINGS_AUTHENDPOINT=$kc/auth \
  -e MM_OPENIDSETTINGS_TOKENENDPOINT=$kc/token \
  -e MM_OPENIDSETTINGS_USERAPIENDPOINT=$kc/userinfo \
  -e MM_OPENIDSETTINGS_BUTTONTEXT=Keycloak \
  "$image" >/dev/null
wait_for mm_ready
wait_for c -f -o /dev/null http://keycloak:8080/realms/test

check "server is unlicensed" [ "$(c "$mm/api/v4/license/client?format=old" | jq -r .IsLicensed)" = false ]
config=$(c "$mm/api/v4/config/client?format=old")
check "client config enables the OpenID button" [ "$(jq -r .EnableSignUpWithOpenId <<<"$config")" = true ]
check "client config carries the button text" [ "$(jq -r .OpenIdButtonText <<<"$config")" = Keycloak ]

# A GitLab SSO user with a team and posts.
c -H "$json" -d '{"email":"admin@example.com","username":"sysadmin","password":"Admin-pw-12345!"}' $mm/api/v4/users >/dev/null
admin=$(token sysadmin 'Admin-pw-12345!')
api() { c -H "Authorization: Bearer $admin" -H "$json" "$@"; }
team=$(api -d '{"name":"dc","display_name":"DC","type":"O"}' $mm/api/v4/teams | jq -r .id)
bob=$(api -d '{"email":"bob@example.com","username":"bob","password":"Bob-pw-12345!"}' $mm/api/v4/users | jq -r .id)
api -d "{\"team_id\":\"$team\",\"user_id\":\"$bob\"}" "$mm/api/v4/teams/$team/members" >/dev/null
channel=$(api "$mm/api/v4/teams/$team/channels/name/town-square" | jq -r .id)
bob_token=$(token bob 'Bob-pw-12345!')
for i in 1 2 3; do
  c -H "Authorization: Bearer $bob_token" -H "$json" \
    -d "{\"channel_id\":\"$channel\",\"message\":\"post $i\"}" $mm/api/v4/posts >/dev/null
done
psql -c "UPDATE users SET authservice = 'gitlab', authdata = '4242', password = '' WHERE id = '$bob';" >/dev/null
api -X POST $mm/api/v4/caches/invalidate >/dev/null

# A new user: two logins land on one account.
check "alice logs in" [ "$(oidc_login alice alice-pw alice1)" = 307 ]
alice=$(session alice1 users/me)
check "alice gets an OpenID account" [ "$(jq -r '[.username, .email, .first_name, .last_name, .auth_service] | join(" ")' <<<"$alice")" = "alice alice@example.com Alice Anders openid" ]
check "alice logs in again" [ "$(oidc_login alice alice-pw alice2)" = 307 ]
check "the second login lands on the same account" [ "$(session alice2 users/me | jq -r .id)" = "$(jq -r .id <<<"$alice")" ]

check "an unverified e-mail address is refused" [ "$(oidc_login carol carol-pw carol0)" = 400 ]
check "no account for carol" [ "$(psql -c "SELECT count(*) FROM users WHERE email = 'carol@example.com';")" = 0 ]

# An account of another provider with the same e-mail and subject.
psql -c "UPDATE users SET authservice = 'gitlab' WHERE username = 'alice';" >/dev/null
api -X POST $mm/api/v4/caches/invalidate >/dev/null
check "an equal subject of another provider is not taken over" [ "$(oidc_login alice alice-pw alice3)" = 400 ]
check "that account keeps its provider" [ "$(psql -c "SELECT authservice FROM users WHERE username = 'alice';")" = gitlab ]
psql -c "UPDATE users SET authservice = 'openid' WHERE username = 'alice';" >/dev/null
api -X POST $mm/api/v4/caches/invalidate >/dev/null

check "an unmigrated GitLab account is not taken over" [ "$(oidc_login bob bob-pw bob0)" = 400 ]
check "no second account for bob" [ "$(psql -c "SELECT count(*) FROM users WHERE email = 'bob@example.com';")" = 1 ]

# The migration, exactly as MIGRATE-FROM-GITLAB.md documents it.
"${docker[@]}" stop mmoidc-mm >/dev/null
"${docker[@]}" exec mmoidc-kc /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
  --realm master --user admin --password admin >/dev/null
read -ra export_users <<<"$(grep -o 'kcadm.sh get users .* > kc_users.csv' "$repo/MIGRATE-FROM-GITLAB.md" |
  sed -e 's/<realm>/test/' -e 's/ > kc_users.csv$//')"
"${docker[@]}" exec mmoidc-kc "/opt/keycloak/bin/${export_users[0]}" "${export_users[@]:1}" > "$work/kc_users.csv"
awk '/^```sql$/ { sql = 1; next } /^```$/ { sql = 0 } sql' "$repo/MIGRATE-FROM-GITLAB.md" > "$work/migrate.sql"
check "the export holds a user without e-mail" grep -q '^,' "$work/kc_users.csv"
"${docker[@]}" cp "$work/kc_users.csv" mmoidc-pg:/tmp/kc_users.csv
"${docker[@]}" cp "$work/migrate.sql" mmoidc-pg:/tmp/migrate.sql
migration=$("${docker[@]}" exec -w /tmp mmoidc-pg psql -U mmuser -d mm -v ON_ERROR_STOP=1 -f migrate.sql)
check "the migration switches one account" grep -qx 'UPDATE 1' <<<"$migration"
"${docker[@]}" start mmoidc-mm >/dev/null
wait_for mm_ready

check "alice's auth data is her Keycloak sub" [ "$(psql -c "SELECT authdata FROM users WHERE username = 'alice';")" = "$(awk -F, '$1 == "alice@example.com" { print $2 }' "$work/kc_users.csv")" ]
check "bob logs in through OpenID" [ "$(oidc_login bob bob-pw bob1)" = 307 ]
check "bob lands on his existing account" [ "$(session bob1 users/me | jq -r .id)" = "$bob" ]
check "bob keeps his team" [ "$(session bob1 users/me/teams | jq -r '.[].name')" = dc ]
check "bob keeps his posts" [ "$(session bob1 "channels/$channel/posts" | jq --arg u "$bob" '[.posts[] | select(.user_id == $u and .type == "")] | length')" = 3 ]
echo "e2e passed for $version"
