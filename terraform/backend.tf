terraform {
  backend "s3" {
    bucket   = "terraform-state"
    key      = "homelab/talos-cluster/terraform.tfstate"
    region   = "us-east-1"
    endpoint = "http://10.9.0.50:9000"

    # Minio specific settings
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}
