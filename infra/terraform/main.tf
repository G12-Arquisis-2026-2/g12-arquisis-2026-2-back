# Base de infraestructura de la E3 (saga en Step Functions).
# Crea: tabla de task tokens, secretos, rol de las Lambdas, rol de Step Functions,
# permisos del EC2 sobre las sagas y permisos del grupo de desarrollo para usar esos roles.
#
# Convención de nombres: las máquinas de estados y las Lambdas deben llamarse "energyshark-*"
# (por ejemplo energyshark-saga-vendedor, energyshark-proponer). Los permisos dependen de ese prefijo.
#
# Los valores de los secretos NO se escriben aquí: se cargan aparte con la CLI,
# para que no queden en el código ni en el estado de Terraform.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = {
      Project   = "energyshark"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  region         = "us-east-2"
  account_id     = data.aws_caller_identity.current.account_id
  prefix         = "energyshark"
  ec2_role_name  = "energyshark-ec2-ecr" # rol existente del EC2 (no lo administra Terraform)
  dev_group_name = "proyecto-arquisis"   # grupo existente de los integrantes

  state_machines_arn = "arn:aws:states:${local.region}:${local.account_id}:stateMachine:${local.prefix}-*"
  lambdas_arn        = "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-*"
}

# ---------------------------------------------------------------------------
# Almacenamiento de task tokens
# token_key = data.idpk (swap-proposed / swap-rejected) o swapId (swap-settled,
# swap-cancelled, swap-expired). expires_at = epoch en segundos (TTL).
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "task_tokens" {
  name         = "${local.prefix}-task-tokens"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "token_key"

  attribute {
    name = "token_key"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# ---------------------------------------------------------------------------
# Secretos (solo el contenedor; el valor se carga con la CLI)
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "wallet_api_key" {
  name        = "${local.prefix}/wallet-api-key"
  description = "API key de la wallet de la central"
}

resource "aws_secretsmanager_secret" "broker" {
  name        = "${local.prefix}/broker"
  description = "Credenciales del broker del curso para publicar desde las Lambdas (JSON)"
}

# ---------------------------------------------------------------------------
# Rol de las Lambdas de la saga
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "saga_lambda" {
  name               = "${local.prefix}-saga-lambda"
  description        = "Rol de ejecucion de las Lambdas de la saga"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "saga_lambda_logs" {
  role       = aws_iam_role.saga_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "saga_lambda" {
  statement {
    sid       = "LeerSecretos"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.wallet_api_key.arn,
      aws_secretsmanager_secret.broker.arn,
    ]
  }

  statement {
    sid = "TaskTokens"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
    ]
    resources = [aws_dynamodb_table.task_tokens.arn]
  }
}

resource "aws_iam_role_policy" "saga_lambda" {
  name   = "${local.prefix}-saga-lambda"
  role   = aws_iam_role.saga_lambda.id
  policy = data.aws_iam_policy_document.saga_lambda.json
}

# ---------------------------------------------------------------------------
# Rol de las máquinas de estados (Step Functions)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "saga_sfn" {
  name               = "${local.prefix}-saga-sfn"
  description        = "Rol de las maquinas de estados de la saga"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "saga_sfn" {
  statement {
    sid     = "InvocarLambdasDeLaSaga"
    actions = ["lambda:InvokeFunction"]
    resources = [
      local.lambdas_arn,
      "${local.lambdas_arn}:*",
    ]
  }

  # Necesario para que la máquina pueda escribir su historial en CloudWatch Logs.
  statement {
    sid = "EntregaDeLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "saga_sfn" {
  name   = "${local.prefix}-saga-sfn"
  role   = aws_iam_role.saga_sfn.id
  policy = data.aws_iam_policy_document.saga_sfn.json
}

# ---------------------------------------------------------------------------
# Permisos del EC2 (connector y relay del outbox) sobre las sagas
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_saga" {
  statement {
    sid       = "IniciarSagas"
    actions   = ["states:StartExecution"]
    resources = [local.state_machines_arn]
  }

  # Estas acciones trabajan con el task token y no aceptan ARN específicos.
  statement {
    sid = "ReanudarSagas"
    actions = [
      "states:SendTaskSuccess",
      "states:SendTaskFailure",
      "states:SendTaskHeartbeat",
    ]
    resources = ["*"]
  }

  statement {
    sid = "BuscarTaskTokens"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:DeleteItem",
    ]
    resources = [aws_dynamodb_table.task_tokens.arn]
  }
}

resource "aws_iam_role_policy" "ec2_saga" {
  name   = "${local.prefix}-ec2-saga"
  role   = local.ec2_role_name
  policy = data.aws_iam_policy_document.ec2_saga.json
}

# ---------------------------------------------------------------------------
# Permiso del grupo de desarrollo para asignar estos roles desde la consola
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "devs_pass_roles" {
  statement {
    sid       = "UsarRolesDeLaSaga"
    actions   = ["iam:PassRole", "iam:GetRole"]
    resources = [
      aws_iam_role.saga_lambda.arn,
      aws_iam_role.saga_sfn.arn,
    ]
  }

  statement {
    sid       = "VerRolesEnLaConsola"
    actions   = ["iam:ListRoles"]
    resources = ["*"]
  }
}

resource "aws_iam_group_policy" "devs_pass_roles" {
  name   = "${local.prefix}-pass-saga-roles"
  group  = local.dev_group_name
  policy = data.aws_iam_policy_document.devs_pass_roles.json
}

# ---------------------------------------------------------------------------
# Salidas
# ---------------------------------------------------------------------------
output "task_tokens_table" {
  value = aws_dynamodb_table.task_tokens.name
}

output "saga_lambda_role_arn" {
  value = aws_iam_role.saga_lambda.arn
}

output "saga_sfn_role_arn" {
  value = aws_iam_role.saga_sfn.arn
}

output "wallet_api_key_secret_arn" {
  value = aws_secretsmanager_secret.wallet_api_key.arn
}

output "broker_secret_arn" {
  value = aws_secretsmanager_secret.broker.arn
}
