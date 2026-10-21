# ==========================================
# RESOURCE GROUP 
# ==========================================

resource "azurerm_resource_group" "hermes" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    project = "hermes-azure"
  }
}

# ==========================================
# 1. Storage Account
#    	-> container Blob hermes-backups -> HERMES_HOME(/opt/data)
# ==========================================

resource "azurerm_storage_account" "hermes" {
  name                = var.storage_account_name
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location

  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true

  allow_nested_items_to_be_public = false

  tags = {
    project   = "hermes-azure"
    component = "persistence"
  }
}

resource "azurerm_storage_container" "backups" {
  name                  = "hermes-backups"
  storage_account_id    = azurerm_storage_account.hermes.id
  container_access_type = "private"
}

# ==========================================
# 2. User Assigned Managed Identity
#    	-> Storage Blob Data Contributor(RBAC) 
# ==========================================

resource "azurerm_user_assigned_identity" "hermes" {
  name                = "${var.name_prefix}-identity"
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location

  tags = {
    project   = "hermes-azure"
    component = "identity"
  }
}

resource "azurerm_role_assignment" "hermes_blob_access" {
  scope                = azurerm_storage_account.hermes.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.hermes.principal_id
}

# ==========================================
# 3. Log Analytics Workspace
# ==========================================

resource "azurerm_log_analytics_workspace" "hermes" {
  name                = "${var.name_prefix}-logs"
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    project   = "hermes-azure"
    component = "monitoring"
  }
}

# ==========================================
# 4. Container Apps Environment -> Log Analytics Workspace
#    	-> Container App 
#       	-> nousresearch/hermes-agent(Image)
# ==========================================

resource "azurerm_container_app_environment" "hermes" {
  name                       = "${var.name_prefix}-env"
  resource_group_name        = azurerm_resource_group.hermes.name
  location                   = azurerm_resource_group.hermes.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hermes.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    minimum_count         = 0
    maximum_count         = 0
  }

  tags = {
    project   = "hermes-azure"
    component = "compute"
  }
}

# ==========================================
# 5. Hermes Container App
#       -> Managed Identity -> RBAC role -> Storage Account
#	-> Container Apps Environment
# ==========================================

resource "azurerm_container_app" "hermes" {
  name                         = "${var.name_prefix}-app"
  resource_group_name          = azurerm_resource_group.hermes.name
  container_app_environment_id = azurerm_container_app_environment.hermes.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.hermes.id]
  }

  secret {
    name  = "discord-bot-token"
    value = var.discord_bot_token
  }

  secret {
    name  = "ollama-api-key"
    value = var.ollama_api_key
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "hermes"
      image  = var.container_image
      cpu    = 1.0
      memory = "2Gi"

      env {
        name  = "HERMES_HOME"
        value = "/opt/data"
      }

      env {
        name        = "DISCORD_BOT_TOKEN"
        secret_name = "discord-bot-token"
      }

      env {
        name        = "OLLAMA_API_KEY"
        secret_name = "ollama-api-key"
      }

      env {
        name  = "DISCORD_ALLOWED_USERS"
        value = var.discord_id
      }

      env {
        name  = "AZURE_STORAGE_ACCOUNT"
        value = var.storage_account_name
      }

      env {
        name  = "AZURE_STORAGE_CONTAINER"
        value = azurerm_storage_container.backups.name
      }

      env {
        name  = "AZURE_BACKUP_PREFIX"
        value = "auto"
      }

    }

  }
}