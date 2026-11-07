variable "tenant_id" {
  type        = string
  description = "Entra tenant. Read from `az account show`; never committed."
}

variable "subscription_id" {
  type        = string
  description = <<-EOT
    sub-lab-dev. Everything this week creates lands here, AND it is the scope
    the Activity log diagnostic setting is attached to. The Activity log is a
    subscription-level log, not a resource-level one, so there is no resource
    to point at: the subscription is the target.
  EOT
}

variable "location" {
  type        = string
  default     = "southcentralus"
  description = "Region for everything this week creates."
}

variable "retention_days" {
  type    = number
  default = 90

  validation {
    condition     = var.retention_days <= 90
    error_message = "Sentinel includes 90 days of retention at no charge; beyond that Log Analytics bills $0.12/GB/month. This week has no reason to exceed it, and exceeding it silently is how a torn-down lab keeps billing. Raise this deliberately or not at all."
  }

  description = <<-EOT
    Workspace retention. Left at 90 because enabling Sentinel on a workspace
    includes the first 90 days at no charge, and this week is destroyed long
    inside that. The validation block is the point: it stops a value that
    starts a meter nobody is watching.
  EOT
}

variable "query_frequency" {
  type        = string
  default     = "PT5M"
  description = <<-EOT
    How often each detection runs. PT5M is the Sentinel minimum for a
    scheduled analytics rule.
  EOT
}

variable "query_period" {
  type    = string
  default = "PT1H"

  description = <<-EOT
    How far back each run looks, and the single most consequential number in
    this week.

    It is deliberately twelve times the frequency rather than equal to it.
    Azure Activity records reach a Log Analytics workspace minutes after the
    operation, and that latency is not a fixed, documented figure -- it varies.
    A rule whose period equals its frequency inspects a five-minute window that
    has probably not been filled yet, finds nothing, and reports healthy
    forever. It does not error. It does not warn. It simply never fires, and a
    detection that never fires looks exactly like an environment with no
    attacks in it.

    Looking back an hour every five minutes means the same event is seen by
    about twelve consecutive runs. That is what incident grouping in
    detections.tf is for: twelve sightings of one event become one incident,
    not twelve.

    The trade is stated rather than hidden: this costs duplicate evaluation to
    buy immunity from an ingestion delay nobody controls.
  EOT
}
