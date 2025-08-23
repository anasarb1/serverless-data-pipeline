terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "data_ingestion" {
  bucket = var.s3_bucket_name

  tags = {
    Name        = "Data Ingestion Bucket"
    Environment = "Dev"
    Project     = "ServerlessDataPipeline"
  }
}

resource "aws_lambda_function" "data_processor" {
  function_name = "data-processor-lambda"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "main.handler"
  runtime       = "python3.9"
  filename      = "../app/lambda_function.zip"
  source_code_hash = filebase64sha256("../app/lambda_function.zip")

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.processed_data.name
      SQS_QUEUE_URL  = aws_sqs_queue.data_queue.id
      KINESIS_STREAM_NAME = aws_kinesis_stream.data_stream.name
    }
  }

  tags = {
    Project = "ServerlessDataPipeline"
  }
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.data_ingestion.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.data_processor.arn
    events              = ["s3:ObjectCreated:*"]
  }
}

resource "aws_dynamodb_table" "processed_data" {
  name           = "processed-data-table"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Project = "ServerlessDataPipeline"
  }
}

resource "aws_sqs_queue" "data_queue" {
  name = "data-processing-queue"

  tags = {
    Project = "ServerlessDataPipeline"
  }
}

resource "aws_kinesis_stream" "data_stream" {
  name        = "data-processing-stream"
  shard_count = 1

  tags = {
    Project = "ServerlessDataPipeline"
  }
}

resource "aws_api_gateway_rest_api" "api" {
  name        = "DataIngestionApi"
  description = "API for data ingestion"
}

resource "aws_api_gateway_resource" "resource" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "data"
}

resource "aws_api_gateway_method" "method" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.resource.id
  http_method = aws_api_gateway_method.method.http_method

  integration_http_method = "POST"
  type                    = "aws_proxy"
  uri                     = aws_lambda_function.data_processor.invoke_arn
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.data_processor.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_iam_role" "lambda_exec" {
  name = "serverless_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_s3_dynamodb_sqs_kinesis_policy" {
  name = "lambda_s3_dynamodb_sqs_kinesis_policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.data_ingestion.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem"
        ]
        Resource = aws_dynamodb_table.processed_data.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.data_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kinesis:PutRecord"
        ]
        Resource = aws_kinesis_stream.data_stream.arn
      }
    ]
  })
}


