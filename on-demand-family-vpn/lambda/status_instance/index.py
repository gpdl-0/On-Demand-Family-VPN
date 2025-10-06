import boto3
import os
import json

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


def lambda_handler(event, context):
    if not _check_key(event):
        return _unauthorized()

    desc = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    inst = desc['Reservations'][0]['Instances'][0]
    state = inst['State']['Name']
    ip = inst.get('PublicIpAddress')
    return {
        "statusCode": 200,
        "body": json.dumps({"state": state, "public_ip": ip, "dns": RECORD_NAME})
    }


