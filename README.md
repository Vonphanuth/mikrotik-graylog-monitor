# MikroTik Graylog Monitor

Centralized MikroTik network, firewall, VPN, security, and administrator activity monitoring using Graylog.

## Current Status

The monitoring configuration has been tested in a LAB environment with:

- MikroTik RouterOS / CHR
- Graylog 6.1
- OpenSearch 2.19
- MongoDB 6
- Docker Compose

The deployment scripts are prepared for fresh-server installation, but the complete installer should be validated on a fresh VM before production rollout.

## Features

Currently tested:

- TCP, UDP and ICMP traffic parsing
- Firewall Forward, Input and Output parsing
- Source and destination IP/port
- Interface in/out
- Source MAC
- Packet length
- TCP flags
- Connection state
- SNAT and DNAT
- Firewall Allowed / Dropped / Rejected actions
- IPsec VPN events
- MikroTik administrator login/logout
- Configuration change audit
- Warning, Error and Critical events
- DNS domain parsing (optional)

## Architecture

MikroTik
   |
   | Syslog UDP/514
   v
Graylog
   |
   +-- Pipeline Rules
   +-- MikroTik Logs Stream
   +-- Search / Dashboard
   |
   v
OpenSearch

MongoDB stores Graylog configuration and metadata.

## Repository Structure

```text
mikrotik-graylog-monitor/
├── install.sh
├── docker-compose.yml
├── .env.example
├── .gitignore
├── scripts/
│   └── setup-graylog.sh
├── graylog/
│   ├── pipeline.json
│   ├── pipeline-rules.json
│   ├── stream.json
│   └── dashboard/
│       └── dashboard-search.json
└── mikrotik/
    └── production-safe.rsc


## Installation

Clone the repository:

```bash
git clone https://github.com/Vonphanuth/mikrotik-graylog-monitor.git
cd mikrotik-graylog-monitor
```

Run the installer:

```bash
chmod +x install.sh scripts/setup-graylog.sh
./install.sh
```

The installer will:

1. Check Docker and Docker Compose.
2. Generate local production secrets.
3. Ask for a Graylog administrator password.
4. Start MongoDB, OpenSearch and Graylog.
5. Wait for Graylog to become healthy.
6. Create the MikroTik Syslog UDP input.
7. Create/reuse the MikroTik Logs stream.
8. Import the stable V15 pipeline rules.
9. Create/update the MikroTik processing pipeline.
10. Connect the pipeline to the stream.

The generated `.env` file stays local and is excluded from Git.

## Graylog Access

Web interface:

```text
http://SERVER_IP:9000
```

MikroTik Syslog:

```text
UDP/514
```

## MikroTik Production Setup

Use:

```text
mikrotik/production-safe.rsc
```

Before using it, replace:

```text
YOUR_GRAYLOG_IP
```

with the production Graylog server IP.

The MikroTik script configures:

- Firewall log forwarding
- Administrator login/logout logging
- Configuration-change auditing
- Warning, Error and Critical logging
- IPsec event logging

It does NOT automatically modify:

- Firewall filter policy
- NAT
- Routes
- IPsec configuration

It also does NOT enable broad logging of every forwarded packet.

## Production Warning

The LAB used broad Forward-chain logging for parser testing.

Do NOT copy this type of rule directly to a busy production router:

```text
chain=forward action=log
```

Production logging should focus on selected security and operational events to avoid excessive RouterOS and Graylog load.

## DNS

MikroTik DNS parsing was tested successfully for domain names and DNS record types.

However, MikroTik raw DNS packet logs do not reliably provide the client IP and requested domain together in one event.

For reliable:

```text
Client IP -> Domain
```

visibility, a dedicated DNS query logger such as AdGuard Home or Pi-hole is recommended as a later phase.

## Security

Never commit:

- `.env`
- Graylog administrator passwords
- `GRAYLOG_PASSWORD_SECRET`
- OpenSearch passwords
- API tokens
- Private keys
- IPsec secrets

Secrets are generated locally during installation.

## Production Rollout

Recommended sequence:

1. Deploy this project on a fresh VM.
2. Confirm all Docker containers are healthy.
3. Confirm Graylog web access.
4. Confirm Syslog UDP/514 input.
5. Configure one test MikroTik.
6. Verify Firewall, ACCOUNT and CONFIG events.
7. Tune production firewall logging volume.
8. Configure retention and alerts.
9. Roll out to additional MikroTik routers.

## Tested Pipeline

The stable migration baseline is:

```text
MikroTik Log Processing V15
```

Experimental service/direction classification rules are kept outside the active pipeline until their processing order is redesigned and validated.

## Deployment Status

The Graylog configuration and parsing rules have been tested in the LAB.

The automated fresh-VM installer is prepared but should be validated on a clean VM before production rollout.
