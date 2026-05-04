# NPA Publisher AWS CloudFormation Deployment

Automated deployment for Netskope Private Access Publishers in AWS using CloudFormation.

![AWS ZTNA Architecture](https://raw.githubusercontent.com/Mitsj0l/nskpub_aws/refs/heads/main/AWS_ZTNA_1.png)

## Overview

This repository contains:

- `netskope-publisher.yaml`
- `netskope-parameters.json`
- `nsk-deployment.sh`

The deployment flow is:

1. CloudFormation creates the AWS resources.
2. User data downloads `nsk-deployment.sh` from S3.
3. The script creates the Publisher in Netskope.
4. The script retrieves the registration token and registers the Publisher.
5. Optional post-registration steps can run automatically:
   - Browser Access AnyApp enablement
   - System update and publisher image upgrade
   - sensitive artifact cleanup

## Prerequisites

### AWS

- AWS account with permissions for:
  - CloudFormation
  - EC2
  - Auto Scaling
  - IAM
  - S3
- An S3 bucket that hosts `nsk-deployment.sh`
- AWS CLI configured with credentials that can deploy the stack

Example:

```bash
aws s3 cp nsk-deployment.sh s3://ztnatemplate/nsk-deployment.sh
```

### Netskope

- Tenant URL
- API token with Publisher management permissions
- Publisher upgrade profile ID

Required API access:

- `/api/v2/infrastructure/publisherupgradeprofiles` read
- `/api/v2/infrastructure/publishers` read and write

## Parameters

The parameter file includes the normal AWS and Netskope settings plus these deployment controls:

- `CleanupSensitiveLogs`
  - `true` removes sensitive local artifacts after successful post-registration steps
- `EnableAnyApp`
  - `true` enables Browser Access AnyApp after Publisher registration
- `UpgradePublisherAfterRegister`
  - `true` runs the interactive upgrade path automatically after registration and AnyApp
- `PublisherUpgrade`
  - Netskope Publisher upgrade profile ID
- `InstanceCount`
  - number of Publisher instances to launch

The sample `netskope-parameters.json` in this repo is intentionally scrubbed and uses placeholders instead of real tenant, token, VPC, subnet, and key pair values.

## AnyApp Sizing

If you plan to use Browser Access AnyApp, review the Netskope guidance before deployment:

- Setup and upgrade guidance:
  - `https://docs.netskope.com/en/upgrade-publisher-resources-for-browser-access-anyapp`
- Configuration guidance:
  - `https://docs.netskope.com/en/configure-browser-access-anyapp#upgrade-publisher-resources--resizing-`

For up to 30 concurrent RDP connections on a single Publisher instance, Netskope recommends:

- 6 CPU cores
- 8 GB RAM
- 30 GB available disk

Because of that, you may want to use `t3.large` instead of `t3.medium` when `EnableAnyApp=true`. Adjust `InstanceType` in `netskope-parameters.json` before deployment if your expected load requires it.

## Deployment

Create the stack:

```bash
aws cloudformation create-stack \
  --stack-name netskope-publishers \
  --template-body file://netskope-publisher.yaml \
  --parameters file://netskope-parameters.json \
  --capabilities CAPABILITY_IAM
```

Update the stack:

```bash
aws cloudformation update-stack \
  --stack-name netskope-publishers \
  --template-body file://netskope-publisher.yaml \
  --parameters file://netskope-parameters.json \
  --capabilities CAPABILITY_IAM
```

## Logging And Troubleshooting

Useful log locations on the instance:

- `/var/log/user-data.log`
- `journalctl -t run-publisher-setup.sh -n 400 --no-pager`
- `/home/ubuntu/logs/run-publisher-setup-<timestamp>.log`
- `/home/ubuntu/logs/publisher-registration-attempt-<n>-<timestamp>.log`
- `/home/ubuntu/logs/publisher-anyapp-enable-<timestamp>.log`
- `/home/ubuntu/logs/publisher-upgrade-<timestamp>.log`
- `/home/ubuntu/logs/publisher_wizard.log`
- `/home/ubuntu/logs/agent.txt`

Notes:

- `publisher_wizard.log` is maintained by Netskope and can contain both failed and successful runs from different invocations.
- The deployment script writes timestamped logs for its own registration, AnyApp, and upgrade actions.
- If `CleanupSensitiveLogs=true`, the script removes sensitive artifacts after successful completion.

## Security Notes

- The CloudFormation template marks tenant URL and API token as `NoEcho`.
- The deployment script avoids writing raw token values into its normal logs.
- The sample parameter file in this repository does not contain live secrets.

## Contributing

Original registration automation inspiration:

- `https://github.com/sartioli/Publisher-auto-register`
