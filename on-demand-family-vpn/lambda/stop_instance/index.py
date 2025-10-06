import boto3
import os
import json

ec2 = boto3.client('ec2')
route53 = boto3.client('route53')

INSTANCE_ID = os.environ['INSTANCE_ID']
HOSTED_ZONE_ID = os.environ['HOSTED_ZONE_ID']
RECORD_NAME = os.environ['RECORD_NAME']
STATIC_API_KEY = os.environ.get('STATIC_API_KEY')
PRESERVE_DNS_ON_STOP = os.environ.get('PRESERVE_DNS_ON_STOP', 'false').lower() == 'true'


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

    ec2.stop_instances(InstanceIds=[INSTANCE_ID])

    # DNS deletion strategy: optional preserve, else only delete if present
    if not PRESERVE_DNS_ON_STOP:
        try:
            existing = _get_existing_a_record(HOSTED_ZONE_ID, RECORD_NAME)
            if existing and existing.get('ResourceRecords'):
                route53.change_resource_record_sets(
                    HostedZoneId=HOSTED_ZONE_ID,
                    ChangeBatch={
                        'Comment': 'Remove VPN A record',
                        'Changes': [{
                            'Action': 'DELETE',
                            'ResourceRecordSet': existing
                        }]
                    }
                )
        except Exception:
            pass

    return {"statusCode": 200, "body": json.dumps({"state": "stopping"})}


