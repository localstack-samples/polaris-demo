-- 1. Create external volume
CREATE OR REPLACE EXTERNAL VOLUME iceberg_volume
  STORAGE_LOCATIONS = (
    (
      NAME = 'aws-s3-test'
  STORAGE_PROVIDER = 'S3'
  STORAGE_BASE_URL = 's3://test-bucket/'
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::000000000000:root'
  ENCRYPTION=(TYPE='AWS_SSE_S3')
    )
  )
  ALLOW_WRITES = TRUE;

-- 2. Create catalog integration
CREATE CATALOG INTEGRATION iceberg_catalog
CATALOG_SOURCE=ICEBERG_REST
TABLE_FORMAT=ICEBERG
CATALOG_NAMESPACE='test_namespace'
REST_CONFIG=(
    CATALOG_URI='http://polaris:8181'
    CATALOG_NAME='polaris'
)
REST_AUTHENTICATION=(
    TYPE=OAUTH
    OAUTH_CLIENT_ID='root'
    OAUTH_CLIENT_SECRET='s3cr3t'
    OAUTH_ALLOWED_SCOPES=(PRINCIPAL_ROLE:ALL)
)
ENABLED=TRUE;
  
-- 3. Create Iceberg table
CREATE ICEBERG TABLE iceberg_table (c1 TEXT)
CATALOG='iceberg_catalog', 
EXTERNAL_VOLUME='iceberg_volume', 
BASE_LOCATION='test/test_namespace';
  
-- 4. Insert data to Iceberg table
INSERT INTO iceberg_table(c1) VALUES ('test'), ('foobar');
  
-- 5. Select data from Iceberg table
SELECT * FROM iceberg_table;