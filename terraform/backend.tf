terraform {
  backend "s3" {
    bucket         = "tutedude-tfstate-aswin-shine" # same bucket as the other assignment — update if you renamed it
    key            = "ci-cd-jenkins-assignment/terraform.tfstate"
    region         = "eu-north-1"
    dynamodb_table = "tutedude-tfstate-lock"
    encrypt        = true
  }
}
