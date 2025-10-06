import boto3
import os
import json
import time

ec2 = boto3.client('ec2')
route53 = boto3.client('route53')

INSTANCE_ID = os.environ['INSTANCE_ID']
HOSTED_ZONE_ID = os.environ['HOSTED_ZONE_ID']
RECORD_NAME = os.environ['RECORD_NAME']
STATIC_API_KEY = os.environ.get('STATIC_API_KEY')


def _unauthorized():
    return {
        "statusCode": 401,
        "body": json.dumps({"message": "unauthorized"})
    }


def _check_key(event):
    if not STATIC_API_KEY:
        return True
    headers = event.get('headers') or {}
    return headers.get('x-api-key') == STATIC_API_KEY


def _get_existing_a_record(zone_id: str, name: str):
    resp = route53.list_resource_record_sets(
        HostedZoneId=zone_id,
        StartRecordName=name,
        StartRecordType='A',
        MaxItems='1'
    )
    rrsets = resp.get('ResourceRecordSets', [])
    if not rrsets:
        return None
    rr = rrsets[0]
    if rr.get('Name', '').rstrip('.') == name.rstrip('.') and rr.get('Type') == 'A':
        return rr
    return None


def lambda_handler(event, context):
    if not _check_key(event):
        return _unauthorized()

    ec2.start_instances(InstanceIds=[INSTANCE_ID])

    # wait for running and fetch public ip
    waiter = ec2.get_waiter('instance_running')
    waiter.wait(InstanceIds=[INSTANCE_ID])

    for _ in range(30):
        desc = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
        inst = desc['Reservations'][0]['Instances'][0]
        ip = inst.get('PublicIpAddress')
        if ip:
            break
        time.sleep(2)
    else:
        return {"statusCode": 500, "body": json.dumps({"message": "no public ip"})}

    # Check current record and avoid unnecessary changes
    existing = _get_existing_a_record(HOSTED_ZONE_ID, RECORD_NAME)
    if existing:
        current_values = [r['Value'] for r in existing.get('ResourceRecords', [])]
        if len(current_values) == 1 and current_values[0] == ip:
            action = None  # no change needed
        else:
            action = 'UPSERT'
    else:
        action = 'CREATE'

    if action:
        route53.change_resource_record_sets(
            HostedZoneId=HOSTED_ZONE_ID,
            ChangeBatch={
                'Comment': 'VPN A record',
                'Changes': [{
                    'Action': action,
                    'ResourceRecordSet': {
                        'Name': RECORD_NAME,
                        'Type': 'A',
                        'TTL': 60,
                        'ResourceRecords': [{'Value': ip}]
                    }
                }]
            }
        )

    return {
        "statusCode": 200,
        "body": json.dumps({"state": "running", "public_ip": ip, "dns": RECORD_NAME})
    }


