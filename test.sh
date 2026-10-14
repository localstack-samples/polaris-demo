#!/usr/bin/env bash
# Walk through the demo end to end on a freshly started stack (`make start`):
# 1. the create-polaris-catalog container set up the `polaris` catalog
# 2. script.sql runs on LocalStack for Snowflake and reads back its two rows
# 3. Trino reads the same Iceberg table through Polaris
# 4. the Iceberg data and metadata files are in the LocalStack S3 bucket
# Requires snowflake-connector-python (`pip install snowflake-connector-python`).
set -euo pipefail
cd "$(dirname "$0")"

export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-test}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-test}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
AWS=${AWS:-aws --endpoint-url=http://localhost:4566}
POLARIS=${POLARIS:-http://localhost:8181}
BUCKET=test-bucket
MAX_ATTEMPTS=${MAX_ATTEMPTS:-90}

# Wait until the one-shot catalog setup container has exited and check it succeeded
container=""
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  container=$(docker compose ps -aq create-polaris-catalog)
  if [ -n "$container" ] && [ "$(docker inspect -f '{{.State.Status}}' "$container")" = "exited" ]; then
    break
  fi
  echo "Attempt $attempt/$MAX_ATTEMPTS: waiting for the Polaris catalog setup"
  sleep 5
done
if [ -z "$container" ] || [ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" != "0" ]; then
  echo "Test failed: the create-polaris-catalog container did not finish successfully"
  docker compose logs create-polaris-catalog || true
  exit 1
fi

token=$(curl -sf -X POST -H "Polaris-Realm: default-realm" "$POLARIS/api/catalog/v1/oauth/tokens" \
  -d grant_type=client_credentials -d client_id=root -d client_secret=s3cr3t -d scope=PRINCIPAL_ROLE:ALL \
  | jq -r .access_token)
location=$(curl -sf -H "Authorization: Bearer $token" "$POLARIS/api/management/v1/catalogs/polaris" \
  | jq -r '.properties["default-base-location"]')
if [ "$location" != "s3://$BUCKET/test" ]; then
  echo "Test failed: Polaris catalog 'polaris' has base location '$location'"
  exit 1
fi
echo "PASS: Polaris catalog 'polaris' exists with base location $location"

$AWS s3api head-bucket --bucket "$BUCKET" 2>/dev/null || $AWS s3 mb "s3://$BUCKET"

# Run script.sql statement by statement and print the rows of the final SELECT
rows=$(python3 - <<'EOF'
import re
import sys
import time

import snowflake.connector

for attempt in range(60):
    try:
        conn = snowflake.connector.connect(
            user="test", password="test", account="test", database="test",
            host="snowflake.localhost.localstack.cloud",
        )
        break
    except Exception as e:
        print(f"Waiting for the Snowflake emulator: {e}", file=sys.stderr)
        time.sleep(5)
else:
    sys.exit("Test failed: could not connect to the Snowflake emulator")

cur = conn.cursor()
cur.execute("CREATE DATABASE IF NOT EXISTS polaris_demo")
cur.execute("USE DATABASE polaris_demo")
cur.execute("USE SCHEMA public")

sql = re.sub(r"^\s*--.*$", "", open("script.sql").read(), flags=re.M)
statements = [s.strip() for s in sql.split(";") if s.strip()]
for statement in statements:
    print(f"> {statement.splitlines()[0]}", file=sys.stderr)
    cur.execute(statement)
for row in sorted(r[0] for r in cur.fetchall()):
    print(row)
EOF
)
if [ "$(echo "$rows" | tr '\n' ' ')" != "foobar test " ]; then
  echo "Test failed: Snowflake returned '$rows' from iceberg_table"
  exit 1
fi
echo "PASS: script.sql created the Iceberg table and Snowflake reads back foobar and test"

trino() {
  docker compose exec -T trino trino --output-format CSV_UNQUOTED --execute "$1"
}
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  trino "SELECT 1" > /dev/null 2>&1 && break
  echo "Attempt $attempt/$MAX_ATTEMPTS: waiting for Trino"
  sleep 5
done
rows=$(trino "SELECT c1 FROM iceberg.test_namespace.iceberg_table ORDER BY c1")
if [ "$(echo "$rows" | tr '\n' ' ')" != "foobar test " ]; then
  echo "Test failed: Trino returned '$rows' from iceberg.test_namespace.iceberg_table"
  exit 1
fi
echo "PASS: Trino reads the same rows through Polaris"

files=$($AWS s3 ls "s3://$BUCKET/test/" --recursive)
echo "$files"
if ! echo "$files" | grep -q '\.parquet$' || ! echo "$files" | grep -q '\.metadata\.json$'; then
  echo "Test failed: no Parquet data files or Iceberg metadata in s3://$BUCKET/test/"
  exit 1
fi
echo "PASS: Iceberg data and metadata files are in s3://$BUCKET/test/"

echo "Test passed: Snowflake and Trino share the Iceberg table through Polaris and LocalStack S3"
