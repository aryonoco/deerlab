# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

# ---------------------------------------------------------------------------
# State encryption
# ---------------------------------------------------------------------------

variable "state_passphrase" {
  description = "Passphrase for PBKDF2 state encryption (>= 16 characters)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}
