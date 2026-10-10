variable "resource_group_name" {
  description = "Name of the Azure Resource Group for the Hermes project."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westeurope"
}

variable "name_prefix" {
  description = "Prefix used for project resources."
  type        = string
  default     = "hermes"
}

variable "storage_account_name" {
  description = "Globally unique Azure Storage Account name."
  type        = string
}

variable "container_image" {
  description = "Hermes Agent container image."
  type        = string
}

variable "discord_id" {
  type        = string
  description = "User ID Discord"
}

variable "discord_bot_token" {
  description = "Discord bot token for Hermes."
  type        = string
  sensitive   = true
}

variable "ollama_api_key" {
  description = "Ollama Cloud API key for Hermes."
  type        = string
  sensitive   = true
}