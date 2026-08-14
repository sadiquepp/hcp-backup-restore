1. Define Variables:

```bash
export BUCKET=adp-backup-bucket-xjt
export REGION=ap-southeast-1
```

1. Create the S3 bucket

```bash
aws s3api create-bucket --bucket $BUCKET --region $REGION --create-bucket-configuration LocationConstraint=$REGION
```

1. Crate IAM Policy for OADP

```bash
cat > adp-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVolumes",
                "ec2:DescribeSnapshots",
                "ec2:CreateTags",
                "ec2:CreateVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObject",
                "s3:AbortMultipartUpload",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET}/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation",
                "s3:ListBucketMultipartUploads"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET}"
            ]
        }
    ]
}
EOF
```

1. Create the IAM user and policy

```bash
aws iam create-user --user-name adp-user
aws iam put-user-policy --user-name adp-user --policy-name adp-policy --policy-document file://adp-policy.json
```

1. Create the IAM access key

```bash
aws iam create-access-key --user-name adp-user
```

1. Create the credentials file. Then edit the file and replace the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY with the actual values from the previous step.

```bash
cat << EOF > ./credentials-adp
[default]
aws_access_key_id=
aws_secret_access_key=
EOF
```

1. Create the secret for cloud credentials

```bash
oc create secret generic cloud-credentials -n openshift-adp --from-file cloud=credentials-adp
```

1. Apply the OADP configuration

```bash
oc apply -f oadp-adp.yaml
```

1. Backup the HCP cluster

```bash
oc apply -f backup-hcp-cluster1.yaml
```

1. Restore the HCP cluster

```bash
oc apply -f restore-hcp-cluster1.yaml
```

