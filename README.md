# expense-infra-vm-v1.2

One `terraform apply` brings up the 3-tier Expense app on EC2, reachable over
HTTPS at `https://expense.<your-domain>`, **with the exporters installed on
every VM and a Prometheus VM running**, and returns only when all of it works.
`terraform destroy` removes everything.

**What v1.2 adds to v1:**
- Instance tags for EC2 service discovery: `Monitoring`, `Tier`, `Component`
  (see [Tags](#tags-for-ec2-service-discovery)).
- Exporters installed by userdata: node_exporter on **every** VM,
  mysqld_exporter on mysql, the NGINX exporter (plus a local-only
  `stub_status`) on frontend. Same versions and layout as the manual scripts.
- A 4th VM, `expense-monitoring`: Prometheus with its **default
  configuration** (it scrapes only itself), and an instance role that lets it
  call the EC2 API. The scrape jobs / `ec2_sd_configs` are yours to write.

All VMs run the course AMI `Redhat-9-DevOps-Practice` (RHEL 9). It uses
**password SSH, no key pair**: user `ec2-user`, password `DevOps321` (practice
credentials, set by the `ssh_user` / `ssh_password` variables).

> **The ALB bills by the hour. Run `terraform destroy` at the end of every lab day.**
>
> v1 and v1.2 create the same names (VPC, SGs, ALB, Route53 records, VMs).
> Run only one of them at a time: destroy v1 before applying v1.2.

## Architecture

```
Internet ──HTTPS:443──▶ ALB  expense.<domain>  (ACM cert, HTTP→HTTPS redirect)
                          │ HTTP:80 (target group → frontend instance)
                          ▼
            expense-frontend   frontend.<domain>   nginx: React build, /api → backend.<domain>:8080
                          │                        + node_exporter :9100, nginx exporter :9113
                          ▼
            expense-backend    backend.<domain>    Node.js API (systemd), DB_HOST=mysql.<domain>
                          │                        + node_exporter :9100, app metrics :9101
                          ▼
            expense-mysql      mysql.<domain>      MySQL 8
                                                   + node_exporter :9100, mysqld_exporter :9104

            expense-monitoring (public IP :9090)   Prometheus, default config
                                                   + node_exporter :9100
                                                   discovers the VMs above via the EC2 API,
                                                   scrapes them over private IPs
```

**The app VMs reach each other only through Route53 names.** Terraform creates
an A record per tier in your public hosted zone, pointing at the VM's private
IP (TTL 60 s):

| Record | Used by |
|---|---|
| `mysql.<domain>` | backend (`DB_HOST`) |
| `backend.<domain>` | frontend nginx (`proxy_pass`) |
| `frontend.<domain>` | nobody in the app; handy for SSH and static scrape configs |

No VM's userdata contains another VM's IP. So:
- Replacing one VM (for example `-replace=aws_instance.backend`) replaces **only that
  VM**. Its record is updated in place and the others keep working.
- nginx re-resolves `backend.<domain>` at request time (VPC resolver, variable
  `proxy_pass`), so it follows a replaced backend within about a minute.
- The records resolve to private addresses, so they only work inside the VPC.
- These record names belong to this stack. Terraform overwrites them if they
  already exist, so don't use them for anything else in the same zone.

The ALB is the only public entry point for the app. It targets the frontend
instance directly (target groups take instances, not names).

The monitoring VM is created **last**, after the three app VMs and the ALB
(`depends_on`). That only orders creation: replacing an app VM later does not
replace the monitoring VM, so the Prometheus data survives app redeploys.

## Tags for EC2 service discovery

Every instance gets these tags (`Project=expense` comes from the provider's
`default_tags`, like `Environment=lab` and `ManagedBy=terraform`):

| Instance | `Monitoring` | `Project` | `Tier` | `Component` |
|---|---|---|---|---|
| `expense-mysql` | `true` | `expense` | `db` | `mysql` |
| `expense-backend` | `true` | `expense` | `backend` | `expense-service` |
| `expense-frontend` | `true` | `expense` | `frontend` | `nginx` |
| `expense-monitoring` | `true` | `expense` | `monitoring` | `prometheus` |

In `ec2_sd_configs` they appear as `__meta_ec2_tag_Monitoring`,
`__meta_ec2_tag_Project`, `__meta_ec2_tag_Tier`, `__meta_ec2_tag_Component`
and `__meta_ec2_tag_Name` (tag keys are case-sensitive). They are also usable
as server-side `filters` (`tag:Monitoring`, `tag:Tier`, …).

Things you'll need when you write the config:
- **Region:** the stack's `aws_region` (`us-east-1` by default).
- **Credentials:** none in `prometheus.yml`. The VM's instance role
  `expense-prometheus` allows `ec2:DescribeInstances` and
  `ec2:DescribeAvailabilityZones`, and the AWS SDK picks it up from instance
  metadata.
- **Addresses:** service discovery sets `__address__` to the instance's
  **private IP** plus the `port` you configure. The security groups allow every
  exporter port from the VPC CIDR, so that works as is.
- **One SD config returns one target per instance**, at one port. A VM with two
  exporters (mysql: 9100 and 9104) needs two jobs (or two SD configs).

Edit the config, check it, reload without a restart:

```bash
sudo vi /etc/prometheus/prometheus.yml
promtool check config /etc/prometheus/prometheus.yml
sudo systemctl reload prometheus          # SIGHUP: re-reads the config
```

Re-running the userdata never overwrites an existing `prometheus.yml`. **A
replaced monitoring VM starts from the default config again**, so keep your
version somewhere else too.

## What gets created

70 resources: 61 in AWS, 9 Terraform-only (4 passwords, 5 readiness checks).
Every taggable AWS resource gets `Project=expense`, `Environment=lab`,
`ManagedBy=terraform`, plus `Name` and `Tier`.

| Area | Terraform resource | AWS name / value | Tier tag | Count |
|---|---|---|---|---|
| **Network** | `aws_vpc.main` | `expense-vpc` (10.0.0.0/16, DNS support on) | `network` | 1 |
| | `aws_subnet.public["a"]`, `["b"]` | `expense-public-a` (10.0.1.0/24), `expense-public-b` (10.0.2.0/24), two AZs | `network` | 2 |
| | `aws_internet_gateway.main` | `expense-igw` | `network` | 1 |
| | `aws_route_table.public` | `expense-public-rt` (0.0.0.0/0 → IGW) | `network` | 1 |
| | `aws_route_table_association.public` | both subnets → `expense-public-rt` | | 2 |
| **Security groups** | `aws_security_group.alb` | `expense-alb-sg` | `edge` | 1 |
| | `aws_security_group.frontend` | `expense-frontend-sg` | `frontend` | 1 |
| | `aws_security_group.backend` | `expense-backend-sg` | `backend` | 1 |
| | `aws_security_group.mysql` | `expense-mysql-sg` | `db` | 1 |
| | `aws_security_group.monitoring` | `expense-monitoring-sg` | `monitoring` | 1 |
| | `aws_vpc_security_group_ingress_rule.*` | ALB 80, 443 from anywhere; frontend 80 from ALB SG; backend 8080 from frontend SG; mysql 3306 from backend SG; 22 from `admin_cidr` on each of the 4 VMs | | 9 |
| | `aws_vpc_security_group_ingress_rule.monitoring` | 9100 on every VM, 9113 frontend, 9101 backend, 9104 mysql, 9090 monitoring; each from `admin_cidr`, the VPC CIDR and every `monitoring_cidrs` entry | | 16 (+8 per `monitoring_cidrs` entry) |
| | `aws_vpc_security_group_egress_rule.all` | all outbound, one per SG | | 5 |
| **IAM** | `aws_iam_role.prometheus` | `expense-prometheus`, assumable by EC2 | `monitoring` | 1 |
| | `aws_iam_role_policy.prometheus_ec2_sd` | inline: `ec2:DescribeInstances`, `ec2:DescribeAvailabilityZones` | | 1 |
| | `aws_iam_instance_profile.prometheus` | `expense-prometheus`, attached to the monitoring VM | `monitoring` | 1 |
| **VMs** | `aws_instance.frontend` | `expense-frontend`, `t3.micro`, 20 GB gp3, nginx + React build, node + nginx exporters | `frontend` | 1 |
| | `aws_instance.backend` | `expense-backend`, `t3.micro`, 20 GB gp3, Node.js API, node_exporter | `backend` | 1 |
| | `aws_instance.mysql` | `expense-mysql`, `t3.micro`, 20 GB gp3, MySQL 8, node + mysqld exporters | `db` | 1 |
| | `aws_instance.monitoring` | `expense-monitoring`, `t3.micro`, 20 GB gp3, Prometheus, node_exporter | `monitoring` | 1 |
| **Load balancer** | `aws_lb.main` | `expense-alb` (internet-facing, both subnets) | `edge` | 1 |
| | `aws_lb_target_group.frontend` | `expense-frontend-tg` (HTTP 80, health check `/healthz`) | `edge` | 1 |
| | `aws_lb_target_group_attachment.frontend` | frontend instance → target group | | 1 |
| | `aws_lb_listener.https` | 443, TLS 1.3/1.2 policy, forwards to the target group | `edge` | 1 |
| | `aws_lb_listener.http` | 80, 301 redirect to HTTPS | `edge` | 1 |
| **TLS** | `aws_acm_certificate.app` | certificate for `expense.<domain>` | `edge` | 1 |
| | `aws_route53_record.cert_validation` | ACM DNS-validation CNAME | | 1 |
| | `aws_acm_certificate_validation.app` | waits until ACM issues the certificate | | 1 |
| **DNS** (in your existing zone) | `aws_route53_record.app` | `expense.<domain>` → ALB (alias) | | 1 |
| | `aws_route53_record.frontend` | `frontend.<domain>` → frontend private IP | | 1 |
| | `aws_route53_record.backend` | `backend.<domain>` → backend private IP | | 1 |
| | `aws_route53_record.mysql` | `mysql.<domain>` → mysql private IP | | 1 |
| **Secrets** (Terraform only, not in AWS) | `random_password.mysql_root`, `.db_app`, `.jwt_secret`, `.mysql_exporter` | MySQL root password, app DB password, JWT secret, mysqld_exporter's MySQL password | | 4 |
| **Readiness** (Terraform only) | `terraform_data.vm_ready["frontend"/"backend"/"mysql"/"monitoring"]` | SSH in, wait for setup, fail on `FAILURE` | | 4 |
| | `terraform_data.app_ready` | `https://expense.<domain>/api/health/ready` must answer 200 | | 1 |

**Read, not created:** the Route53 hosted zone (`data.aws_route53_zone`), the
AMI (`data.aws_ami.joindevops`) and the availability zones.

**Not created on purpose:** no NAT gateway, no EC2 key pair (password SSH), no
Route53 record for Prometheus (open it by public IP), no Grafana /
Alertmanager / blackbox_exporter yet, no Auto Scaling group, no remote state.

**What costs money while it runs:** the ALB (hourly plus LCU), the four
t3.micro instances, their 20 GB gp3 volumes and the public IPv4 addresses
(ALB and instances). Route53 queries are cents. ACM certificates and IAM are free.

## Prerequisites

- AWS credentials configured (`aws sts get-caller-identity` works), allowed to
  create IAM roles and instance profiles (new in v1.2).
- A **Route53 public hosted zone** for your domain, already delegated.
- Terraform ≥ 1.6.
- No SSH key needed: the course AMI uses `ec2-user` / `DevOps321`.
- The three app repos reachable over HTTPS (public), with the code on `main`.
- The VMs download the exporters and Prometheus from GitHub releases (they
  have public IPs and full outbound access).

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in domain, admin_cidr, repo URLs/refs
terraform init
terraform apply
```

Takes about 15–20 minutes. Apply finishes in this order:
1. Network, security groups, IAM role, certificate (validated through Route53).
2. `mysql` VM → `mysql.<domain>` → `backend` VM → `backend.<domain>` →
   `frontend` VM. Each VM waits for its upstream's record to exist first:
   a lookup of a name that doesn't exist yet would be cached as "no such name"
   for up to 15 minutes.
3. `monitoring` VM, once the three app VMs and the ALB exist.
4. Readiness: per VM, SSH in, wait for setup, and fail if
   `/var/log/expense/setup.log` has a `FAILURE`. Each exporter must answer with
   real data (`node_load1`, `mysql_up 1`, `nginx_up 1`, the backend's
   `expense_backend_build_info`, Prometheus `/-/ready`).
5. End to end: from the frontend VM, `https://expense.<domain>/api/health/ready`
   must answer 200 within about 5 minutes, or the apply fails.

Outputs: `app_url`, `prometheus_url`, `ssh_commands`, `tier_hostnames`,
`private_ips`, `instance_tags`, and (sensitive) `db_password`,
`mysql_root_password`, `jwt_secret`, `mysql_exporter_password`:

```bash
terraform output prometheus_url    # http://<public ip>:9090, from admin_cidr only
terraform output ssh_commands      # ssh ec2-user@<public ip>, password DevOps321
terraform output -raw db_password
```

## Deploy new app code

Each VM clones its repo's `main` branch (`*_repo_ref`) once, when it is
created. New commits on `main` are **not** picked up automatically: Terraform
only sees that `"main"` hasn't changed. To redeploy a tier with the latest
`main`, rebuild just that VM:

```bash
terraform apply -replace=aws_instance.backend    # or .frontend / .mysql
```

Its Route53 record follows the new private IP and the other VMs are untouched.
Service discovery picks up the new instance on its next refresh (60 s by
default); the old one disappears from the targets. Counters on the new VM start
from 0, which `rate()` / `increase()` handle as a reset.

Changing a `*_repo_ref` to another branch (or tag) and applying does the same.
So does changing an exporter version variable: it re-renders that VM's
userdata, which replaces the VM.

Extra backend settings go in `backend_extra_env` (written as-is into
`/etc/expense/backend.env`, overriding earlier values):

```hcl
backend_extra_env = {
  ENABLE_DEBUG_API = "true"
  DEBUG_TOKEN      = "change-me-please"
}
```

The backend env file always gets `APP_REF=<backend_repo_ref>`, which the app
reports in `expense_backend_build_info`. If you set `METRICS_PORT` here, the
security group and the setup check follow it.

## On the VMs

| | frontend | backend | mysql | monitoring |
|---|---|---|---|---|
| Hostname | `expense-frontend` | `expense-backend` | `expense-mysql` | `expense-monitoring` |
| App directory | `/opt/expense/frontend` (build), `/usr/share/nginx/html` (served) | `/opt/expense/backend` | `/opt/expense/mysql` (migrations) | |
| Service | `nginx` | `expense-backend` (user `expense`) | `mysqld` | `prometheus` (user `prometheus`) |
| Config | `/etc/nginx/conf.d/expense.conf` | `/etc/expense/backend.env` (600) | `/etc/my.cnf.d/zz-expense.cnf` | `/etc/prometheus/prometheus.yml`, data in `/var/lib/prometheus` |
| Exporters | `node_exporter`, `nginx_exporter` | `node_exporter` | `node_exporter`, `mysqld_exporter` | `node_exporter` |
| Setup log | `/var/log/expense/setup.log` | same | same | same |

Exporters and Prometheus come from the GitHub release tarballs, checked
against the release's SHA-256 checksums file, and are laid out like the manual
scripts in `docs/`:

```
/opt/<name>-<version>/   the release, owned by system user <name>
/opt/<name>              symlink to it; the systemd unit runs /opt/<name>/...
```

| Port | What | VM | Version variable | Checked at setup |
|---|---|---|---|---|
| 9100 | node_exporter | all | `node_exporter_version` (1.12.1) | `node_load1` present |
| 9101 | backend app metrics (built into the app) | backend | – | `expense_backend_build_info` present |
| 9104 | mysqld_exporter | mysql | `mysqld_exporter_version` (0.21.0) | `mysql_up 1` |
| 9113 | NGINX Prometheus exporter | frontend | `nginx_exporter_version` (1.5.3) | `nginx_up 1` |
| 9090 | Prometheus | monitoring | `prometheus_version` (3.16.0) | `/-/ready` |

Details:
- **mysqld_exporter** logs in as `'exporter'@'127.0.0.1'` (`PROCESS`,
  `REPLICATION CLIENT`, `SELECT`, max 3 connections), password from
  `random_password.mysql_exporter`, stored in `/etc/mysqld_exporter/.my.cnf`
  (600).
- **nginx exporter** reads `http://127.0.0.1:8081/stub_status`, a separate
  nginx server bound to localhost only (`/etc/nginx/conf.d/stub_status.conf`,
  `access_log off`). Each scrape still adds 1 to nginx's request counter, as
  do the ALB health checks.
- Monitoring ports are open from `admin_cidr`, the VPC CIDR (10.0.0.0/16) and
  any `monitoring_cidrs`. From your machine:
  `curl http://<public ip>:9100/metrics`.
- firewalld is inactive on this AMI. If it is running, the scripts open each
  port there too.

## Destroy

```bash
terraform destroy
```

Removes everything, including the Route53 records and the IAM role it created.
The hosted zone itself is untouched.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Apply fails at `terraform_data.vm_ready["<tier>"]` | The output shows the tail of that VM's `setup.log`. SSH in: `sudo less /var/log/expense/setup.log`, `sudo cloud-init status --long` |
| `download ... FAILURE` / `verify SHA-256 ... FAILURE` | The version variable names a release that doesn't exist, or GitHub was unreachable. Check the URL in the log |
| `... answers on :<port> ... FAILURE` | `systemctl status <name>`, `journalctl -u <name> -n 50`. mysqld_exporter: `mysql_up 0` means its login failed. nginx exporter: `curl http://127.0.0.1:8081/stub_status` |
| `clone ... FAILURE` | The repo URL is wrong or private, or the `*_repo_ref` branch doesn't exist on GitHub |
| Backend never ready | On the backend: `journalctl -u expense-backend -n 100`; `getent hosts mysql.<domain>`; on mysql: `systemctl status mysqld` |
| 502 from the app | On the frontend: `getent hosts backend.<domain>`, `curl -v http://backend.<domain>:8080/api/health/live`, `sudo tail /var/log/nginx/error.log` |
| Apply fails at `app_ready` | DNS or the ALB: `dig expense.<domain>`, target group health in the console |
| EC2 SD finds nothing | Prometheus log: `journalctl -u prometheus -n 50` (`UnauthorizedOperation` = role not attached; check `region`). Status → Service Discovery in the UI shows the discovered labels before relabelling |
| Certificate validation hangs | The hosted zone isn't the one your registrar delegates to (NS records mismatch) |
| `Error: no matching Route 53 Hosted Zone` | `domain_name` must be an existing public hosted zone in this account |
