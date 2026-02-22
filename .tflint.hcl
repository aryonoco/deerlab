# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

config {
  format = "compact"

  call_module_type = "local"
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_empty_list_equality" {
  enabled = true
}

# deerlab uses a flat tofu/ directory, not a multi-module structure
rule "terraform_standard_module_structure" {
  enabled = false
}

# Provider and version blocks are present in versions.tf
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_workspace_remote" {
  enabled = false
}
