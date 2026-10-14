#!/bin/sh

# Wait for Polaris to be ready
echo "Waiting for Polaris to be ready..."
until curl -s http://polaris:8182/healthcheck > /dev/null; do
    sleep 2
done
echo "Polaris is ready!"

# Get bearer token
echo "Getting bearer token..."
if ! output=$(curl -s -X POST -H "Polaris-Realm: default-realm" "http://polaris:8181/api/catalog/v1/oauth/tokens" \
  -d "grant_type=client_credentials" \
  -d "client_id=root" \
  -d "client_secret=s3cr3t" \
  -d "scope=PRINCIPAL_ROLE:ALL"); then
    echo "Failed to get bearer token"
    exit 1
fi

token=$(echo "$output" | awk -F\" '{print $4}')

if [ -z "$token" ] || [ "$token" = "unauthorized_client" ]; then
    echo "Failed to get bearer token"
    exit 1
fi

PRINCIPAL_TOKEN=$token
echo "Bearer token obtained successfully"

# Create catalog. A 409 means it already exists, for example when the script runs again.
echo "Creating Polaris catalog..."
status=$(curl -s -o /tmp/create-catalog.json -w '%{http_code}' -X POST -H "Authorization: Bearer $PRINCIPAL_TOKEN" -H 'Accept: application/json' -H 'Content-Type: application/json' \
  http://polaris:8181/api/management/v1/catalogs \
  -d '{
        "catalog": {
          "name": "polaris",
          "type": "INTERNAL",
          "properties": {
            "default-base-location": "s3://test-bucket/test"
          },
          "storageConfigInfo": {
            "storageType": "S3_COMPATIBLE",
            "allowedLocations": [
              "s3://test-bucket/"
            ],
            "s3.roleArn": "arn:aws:iam::000000000000:role/test-bucket",
            "externalId": null,
            "userArn": null,
            "region": "us-east-1",
            "s3.pathStyleAccess": true,
            "s3.endpoint": "http://localstack:4566"
          }
        }
      }')
case "$status" in
  2*) echo "Catalog created successfully" ;;
  409) echo "Catalog already exists" ;;
  *) echo "Failed to create catalog (HTTP $status)"; cat /tmp/create-catalog.json; exit 1 ;;
esac

# Add TABLE_WRITE_DATA to catalog_admin role
echo "Adding TABLE_WRITE_DATA privilege to catalog_admin role..."
status=$(curl -s -o /tmp/grant.json -w '%{http_code}' -X PUT -H "Authorization: Bearer $PRINCIPAL_TOKEN" -H 'Accept: application/json' -H 'Content-Type: application/json' \
  http://polaris:8181/api/management/v1/catalogs/polaris/catalog-roles/catalog_admin/grants \
  -d '{"type": "catalog", "privilege": "TABLE_WRITE_DATA"}')
case "$status" in
  2*) ;;
  *) echo "Failed to add TABLE_WRITE_DATA privilege (HTTP $status)"; cat /tmp/grant.json; exit 1 ;;
esac
echo "TABLE_WRITE_DATA privilege added successfully"
echo "Polaris catalog setup completed successfully!" 