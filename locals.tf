locals {
  app_fqdn = "${var.app_hostname}.${var.domain_name}"

  # Components reach each other ONLY through these Route53 names, never through
  # IPs baked into userdata (naming-conventions §2.3: <service>.<domain_name>).
  # A replaced VM gets a new private IP; its record is updated in place and the
  # other VMs keep working without being rebuilt.
  tier_hostnames = {
    frontend = "frontend.${var.domain_name}"
    backend  = "backend.${var.domain_name}"
    mysql    = "mysql.${var.domain_name}"
  }

  # Short TTL so a replaced VM is reachable again within about a minute.
  internal_record_ttl = 60

  backend_port = 8080
  mysql_port   = 3306

  # The backend's own metrics port (the app's default, unless overridden via
  # backend_extra_env). Used by the security group and the setup check.
  backend_metrics_port = tonumber(lookup(var.backend_extra_env, "METRICS_PORT", "9101"))

  # ---- instance tags: what EC2 service discovery filters and relabels on --------
  # Prometheus sees each one as __meta_ec2_tag_<Key>, e.g. __meta_ec2_tag_Tier.
  # Project (= var.project) comes from the provider's default_tags.
  # Monitoring = "true" marks an instance as a scrape target.
  instance_tags = {
    mysql      = { Tier = "db", Component = "mysql" }
    backend    = { Tier = "backend", Component = "expense-service" }
    frontend   = { Tier = "frontend", Component = "nginx" }
    monitoring = { Tier = "monitoring", Component = "prometheus" }
  }

  # Shared bash helpers (download + checksum, node_exporter, service start),
  # inserted into every userdata script.
  monitoring_lib = file("${path.module}/templates/monitoring-lib.sh")
}
