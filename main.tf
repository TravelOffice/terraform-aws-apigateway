variable "ENV" {
  description = "Environment"
}
variable "LAMBDA_ARNS" {
  description = "List lambda arns"
}
variable "API_ENDPOINTS" {
  description = "List params of api gateway"
}
variable "AWS_REGION" {
  description = "Amazon region"
}
variable "FEATURE_NAME" {
  description = "Feature name"
}
variable "DOMAIN_NAME" {
  description = "Domain name"
  default     = ""
}
variable "HOSTED_ZONE_ID" {
  description = "Route53 hosted zone id"
  default     = ""
}
variable "DOMAIN_CERTIFICATE_ARN" {
  description = "Domain certificate arn"
  default     = ""
}
variable "TAGS" {
  description = "List tags"
}

variable "COGNITO_USER_POOL_ARN" {
  description = "Cognito User Pool Arn"
}

variable "CORS_CONFIGURATION" {
  description = "Cognito User Pool Arn"
  default = {
    allow_headers = ["Content-Type", "X-Amz-Date,Authorization", "X-Api-Key", "X-Amz-Security-Token"]
    allow_methods = ["*"]
    allow_origins = ["*"]
  }
}

locals {
  domain_number = var.DOMAIN_NAME == "" ? 0 : 1
}

# Get current aws account information
data "aws_caller_identity" "current" {}

resource "aws_api_gateway_rest_api" "rest_api" {
  body = jsonencode({
    openapi = "3.0.1"
    info = {
      title   = "${var.ENV}-${var.FEATURE_NAME}"
      version = "1.0"
    }
    components = {
      securitySchemes = {
        lower("${var.ENV}-${var.FEATURE_NAME}-authorizers") = {
          type                           = "apiKey"
          name                           = "Authorization"
          in                             = "header"
          "x-amazon-apigateway-authtype" = "cognito_user_pools"
          "x-amazon-apigateway-authorizer" = {
            type         = "cognito_user_pools"
            providerARNs = [var.COGNITO_USER_POOL_ARN]
          }
        }
      }
    }
    paths = {
      for pathKey, pathValue in var.API_ENDPOINTS : pathKey => merge(
        {
          for methodKey, methodValue in pathValue : lower(methodKey) => {
            security = methodValue.authorization ? [{ lower("${var.ENV}-${var.FEATURE_NAME}-authorizers") = [] }] : []
            x-amazon-apigateway-integration = {
              httpMethod           = "POST"
              payloadFormatVersion = "1.0"
              type                 = "AWS_PROXY"
              uri                  = "arn:aws:apigateway:${var.AWS_REGION}:lambda:path/2015-03-31/functions/${var.LAMBDA_ARNS[methodValue.lambda_name]}/invocations"
            }
          }
        },
        {
          options = {
            summary     = "CORS support",
            description = "Enable CORS by returning correct headers\n",
            tags = [
              "CORS"
            ],
            responses = {
              200 = {
                description = "Default response for CORS method",
                headers = {
                  Access-Control-Allow-Origin = {
                    schema = {
                      type = "string"
                    }
                  },
                  Access-Control-Allow-Methods = {
                    schema = {
                      type = "string"
                    }
                  },
                  Access-Control-Allow-Headers = {
                    schema = {
                      type = "string"
                    }
                  }
                },
                content = {}
              }
            },
            x-amazon-apigateway-integration = {
              type = "mock",
              requestTemplates = {
                "application/json" = "{\n  \"statusCode\" : 200\n}\n"
              },
              responses = {
                default = {
                  statusCode = "200",
                  responseParameters = {
                    "method.response.header.Access-Control-Allow-Headers" = format("'%s'", join(",", var.CORS_CONFIGURATION.allow_headers)),
                    "method.response.header.Access-Control-Allow-Methods" = format("'%s'", join(",", var.CORS_CONFIGURATION.allow_methods)),
                    "method.response.header.Access-Control-Allow-Origin"  = format("'%s'", join(",", var.CORS_CONFIGURATION.allow_origins)),
                  },
                  responseTemplates = {
                    "application/json" = "{}\n"
                  }
                }
              }
            }
          }
        }
      )
    }
  })

  name = lower("${var.ENV}-${var.FEATURE_NAME}")

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.TAGS
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id

  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.rest_api.body))
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  mapping_method_lambda_name = flatten([
    for path in keys(var.API_ENDPOINTS) : [
      for key, value in var.API_ENDPOINTS[path] : {
        path           = path
        statement_path = replace(path, "/[^a-zA-Z0-9 -]/", "_")
        method         = key
        lambda_name    = value.lambda_name
      }
    ]
  ])
}

resource "aws_lambda_permission" "api_gatewway_invoke_lambda_permission" {
  for_each      = { for api in local.mapping_method_lambda_name : lower("${api.path}_${api.method}") => api }
  statement_id  = "${var.ENV}-${var.FEATURE_NAME}-${each.value.statement_path}-${each.value.method}"
  action        = "lambda:InvokeFunction"
  function_name = "${var.ENV}-${var.FEATURE_NAME}-${each.value.lambda_name}"
  principal     = "apigateway.amazonaws.com"

  # More: http://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-control-access-using-iam-policies-to-invoke-api.html
  source_arn = "arn:aws:execute-api:${var.AWS_REGION}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rest_api.id}/*/${each.value.method}${each.value.path}"
}

resource "aws_api_gateway_stage" "api_gateway_stage" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = var.ENV
  tags          = var.TAGS
}

resource "aws_api_gateway_domain_name" "domain_name" {
  count                    = local.domain_number
  domain_name              = lower("${var.ENV}-${var.FEATURE_NAME}.${var.DOMAIN_NAME}")
  regional_certificate_arn = var.DOMAIN_CERTIFICATE_ARN

  endpoint_configuration {
    types = ["REGIONAL"]
  }
  tags = var.TAGS
}

# DNS record using Route53.
# Route53 is not specifically required; any DNS host can be used.
resource "aws_route53_record" "route53_record" {
  count = local.domain_number
  depends_on = [
    aws_api_gateway_domain_name.domain_name
  ]
  name    = aws_api_gateway_domain_name.domain_name[0].domain_name
  type    = "A"
  zone_id = var.HOSTED_ZONE_ID

  alias {
    evaluate_target_health = true
    name                   = aws_api_gateway_domain_name.domain_name[0].regional_domain_name
    zone_id                = aws_api_gateway_domain_name.domain_name[0].regional_zone_id
  }
}

resource "aws_api_gateway_base_path_mapping" "path_mapping" {
  count = local.domain_number
  depends_on = [
    aws_api_gateway_domain_name.domain_name
  ]
  api_id      = aws_api_gateway_rest_api.rest_api.id
  stage_name  = aws_api_gateway_stage.api_gateway_stage.stage_name
  domain_name = aws_api_gateway_domain_name.domain_name[0].domain_name
}


output "raw_url" {
  value = aws_api_gateway_deployment.deployment.invoke_url
}

output "domain_url" {
  value = aws_api_gateway_domain_name.domain_name[*].domain_name
}
