import json
import os
import boto3

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")
kinesis = boto3.client("kinesis")

def handler(event, context):
    print(f"Received event: {json.dumps(event)}")

    # Handle S3 events
    if "Records" in event and event["Records"][0].get("eventSource") == "aws:s3":
        for record in event["Records"]:
            bucket_name = record["s3"]["bucket"]["name"]
            object_key = record["s3"]["object"]["key"]
            print(f"New object created in S3: {bucket_name}/{object_key}")

            try:
                response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
                file_content = response["Body"].read().decode("utf-8")
                print(f"File content: {file_content}")

                # Process data (example: store in DynamoDB)
                table_name = os.environ.get("DYNAMODB_TABLE")
                if table_name:
                    table = dynamodb.Table(table_name)
                    item = {"id": object_key, "content": file_content}
                    table.put_item(Item=item)
                    print(f"Stored item in DynamoDB table {table_name}: {item}")

                # Send message to SQS
                sqs_queue_url = os.environ.get("SQS_QUEUE_URL")
                if sqs_queue_url:
                    sqs.send_message(QueueUrl=sqs_queue_url, MessageBody=json.dumps(item))
                    print(f"Sent message to SQS queue {sqs_queue_url}")

                # Send data to Kinesis
                kinesis_stream_name = os.environ.get("KINESIS_STREAM_NAME")
                if kinesis_stream_name:
                    kinesis.put_record(
                        StreamName=kinesis_stream_name,
                        Data=json.dumps(item),
                        PartitionKey=object_key
                    )
                    print(f"Sent data to Kinesis stream {kinesis_stream_name}")

            except Exception as e:
                print(f"Error processing S3 object {object_key}: {e}")
                raise e

    # Handle API Gateway events (example: direct data ingestion)
    elif event.get("httpMethod"):
        try:
            body = json.loads(event["body"])
            print(f"Received API Gateway request with body: {body}")

            # Process data (example: store in DynamoDB)
            table_name = os.environ.get("DYNAMODB_TABLE")
            if table_name:
                table = dynamodb.Table(table_name)
                item = {"id": body.get("id", "api-data-" + str(json.dumps(body).__hash__())), "data": body}
                table.put_item(Item=item)
                print(f"Stored item in DynamoDB table {table_name}: {item}")

            return {
                "statusCode": 200,
                "body": json.dumps({"message": "Data processed successfully"})
            }
        except Exception as e:
            print(f"Error processing API Gateway request: {e}")
            return {
                "statusCode": 500,
                "body": json.dumps({"message": f"Error: {str(e)}"})
            }

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "Event processed"})
    }


