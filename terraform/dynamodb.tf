resource "aws_dynamodb_table" "auth_partners" {
  name         = var.auth_partners_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "client_id"

  attribute {
    name = "client_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}
