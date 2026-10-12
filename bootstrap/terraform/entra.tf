resource "azuread_group" "sql_admins" {
  for_each = var.environments

  display_name            = "${var.name_prefix}-sg-sql-admins-${each.key}"
  mail_nickname           = "${var.name_prefix}-sg-sql-admins-${each.key}"
  description             = "Microsoft Entra admins of the ${var.name_prefix} ${each.key} Azure SQL server."
  security_enabled        = true
  prevent_duplicate_names = true
  owners                  = var.entra_group_owner_object_ids

  # The apply identity creates the API's contained database user after each apply.
  members = concat(
    [azurerm_user_assigned_identity.pipeline["${each.key}-apply"].principal_id],
    each.value.sql_admin_member_object_ids,
  )

  lifecycle {
    prevent_destroy = true
  }
}
