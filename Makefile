.PHONY: all install clean

PREFIX ?= $(HOME)/.local/share/noctalia/plugins
PLUGIN_DIR = $(PREFIX)/audio-sticker

all:
	$(MAKE) -C native

install: all
	mkdir -p $(PLUGIN_DIR)
	rsync -a --exclude='.*' \
		plugin.toml service.luau widget.luau translations native bin \
		README.md LICENSE thumbnail.webp \
		$(PLUGIN_DIR)/

clean:
	$(MAKE) -C native clean
