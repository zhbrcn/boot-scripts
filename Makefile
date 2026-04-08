# Makefile for boot-scripts

PREFIX ?= /opt/boot-scripts
SYSTEMD_DIR ?= /etc/systemd/system

.PHONY: install
install:
	@echo "Installing boot-scripts to $(PREFIX)..."
	install -d $(PREFIX) $(PREFIX)/bin $(PREFIX)/scripts $(PREFIX)/lib $(PREFIX)/config
	install -m 0755 bin/boot.sh $(PREFIX)/bin/boot.sh
	install -m 0755 scripts/*.sh $(PREFIX)/scripts/
	install -m 0644 lib/*.sh $(PREFIX)/lib/
	install -m 0644 config/sshman.conf.example $(PREFIX)/config/
	install -m 0644 systemd/boot-scripts.service $(SYSTEMD_DIR)/
	sed -i 's|%SCRIPT_DIR%|$(PREFIX)|g' $(SYSTEMD_DIR)/boot-scripts.service
	systemctl daemon-reload
	systemctl enable boot-scripts.service
	@echo "installed to $(PREFIX)"
	@echo "enabled boot-scripts.service - run 'sudo systemctl start boot-scripts' to test"

.PHONY: uninstall
uninstall:
	@echo "Removing boot-scripts..."
	-systemctl disable boot-scripts.service 2>/dev/null || true
	-rm -f $(SYSTEMD_DIR)/boot-scripts.service
	-rm -rf $(PREFIX)
	@echo "done"

.PHONY: test lint
test lint:
	@which shellcheck >/dev/null 2>&1 && \
		shellcheck -x -S warning bin/boot.sh scripts/*.sh lib/*.sh || \
		echo "shellcheck not installed - skipping"

.PHONY: bootstrap
bootstrap:
	./bin/boot.sh --bootstrap

.PHONY: help
help:
	@grep -E '^\.PHONY|^\w+:' Makefile | grep -v '\.PHONY' | sed 's/:.*//' | while read t; do echo "  make $$t"; done
	@echo ""
	@echo "  make install     install + enable systemd service"
	@echo "  make uninstall   remove + disable service"
	@echo "  make test        shellcheck all scripts"
	@echo "  make bootstrap   download scripts from GitHub"
