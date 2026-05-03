provider "azuread" {
  use_oidc = true
}

provider "msgraph" {
  use_oidc = true
}
