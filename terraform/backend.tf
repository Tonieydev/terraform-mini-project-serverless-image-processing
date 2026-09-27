terraform {
  backend "s3" {
    bucket  = "toney-test-bucket-statefile1"
    key     = "dev/terraform.tfstate"
    region  = "us-east-1"
    profile = "Vscode-TERRAFORM"
  }
}