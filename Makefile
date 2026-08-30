# RAGFlow + Khoj dual-stack. Every target is idempotent; destructive
# paths take a backup first. Secrets live in per-stack .env files.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OPS  := $(ROOT)/ops

.PHONY: help preflight init-env up down status backup restore \
	up-ragflow up-khoj down-ragflow down-khoj logs logs-ragflow logs-khoj \
	check-lib

help:
	@printf '%s\n' \
	  'RAGFlow + Khoj dual-stack' \
	  '' \
	  '  make init-env      Create per-stack .env from examples (keeps existing secrets)' \
	  '  make preflight     Host checks (iptables, ports via /dev/tcp, vm.max_map_count, RAM)' \
	  '  make up            Start both stacks (isolated compose projects)' \
	  '  make up-ragflow    Start RAGFlow only (web :8081)' \
	  '  make up-khoj       Start Khoj only (web :42110)' \
	  '  make down          Stop both stacks (keeps volumes)' \
	  '  make status        Compose ps + TCP probes' \
	  '  make backup        Snapshot volumes + .env into backups/<utc>/' \
	  '  make restore BACKUP=backups/<utc>   Restore after auto-backup of current state' \
	  '  make logs          Tail both stacks' \
	  '' \
	  'Stacks never share compose project, network, volumes, or host ports.'

check-lib:
	@bash -n "$(OPS)/lib.sh"
	@# shellcheck disable=SC1091
	@bash -c 'source "$(OPS)/lib.sh" && assert_tcp_probe_available && ok "lib.sh + /dev/tcp probe are usable"'

preflight:
	@$(OPS)/preflight.sh

init-env:
	@$(OPS)/init-env.sh

up: init-env preflight up-ragflow up-khoj
	@$(OPS)/status.sh

up-ragflow: init-env
	@$(OPS)/preflight.sh
	@# shellcheck disable=SC1091
	@bash -c 'source "$(OPS)/lib.sh" && ragflow_compose up -d'

up-khoj: init-env
	@$(OPS)/preflight.sh
	@# shellcheck disable=SC1091
	@bash -c 'source "$(OPS)/lib.sh" && khoj_compose up -d'

down:
	@# shellcheck disable=SC1091
	@bash -c 'source "$(OPS)/lib.sh"; \
	  if [[ -f "$$RAGFLOW_DIR/.env" ]]; then ragflow_compose down --remove-orphans; else warn "ragflow .env missing, skip"; fi; \
	  if [[ -f "$$KHOJ_DIR/.env" ]]; then khoj_compose down --remove-orphans; else warn "khoj .env missing, skip"; fi'

down-ragflow:
	@# shellcheck disable=SC1091
	@bash -c 'source "$(OPS)/lib.sh" && ragflow_compose down --remove-orphans'

down-khoj:
	@# shellcheck disable=SC1091
	@bash -c 'source "$(OPS)/lib.sh" && khoj_compose down --remove-orphans'

status:
	@$(OPS)/status.sh

backup:
	@$(OPS)/backup.sh

restore:
	@if [[ -z "$(BACKUP)" ]]; then echo "usage: make restore BACKUP=backups/<utc>" >&2; exit 1; fi
	@$(OPS)/restore.sh "$(BACKUP)"

logs:
	@$(MAKE) logs-ragflow
	@$(MAKE) logs-khoj

logs-ragflow:
	@# shellcheck disable=SC1091
	@bash -c 'source "$(OPS)/lib.sh" && ragflow_compose logs --tail=80'

logs-khoj:
	@# shellcheck disable=SC1091
	@bash -c 'source "$(OPS)/lib.sh" && khoj_compose logs --tail=80'
